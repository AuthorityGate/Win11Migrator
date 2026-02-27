<#
========================================================================================================
    Title:          Win11Migrator - Accessibility Settings Importer
    Filename:       Import-AccessibilitySettings.ps1
    Description:    Restores Windows accessibility settings (StickyKeys, FilterKeys, HighContrast, etc.)
                    on the target machine.
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
    Restores Windows accessibility settings on the target machine.
.DESCRIPTION
    Reads exported accessibility settings from the migration package and restores
    StickyKeys, FilterKeys, ToggleKeys, MouseKeys, HighContrast, Narrator, and
    Magnifier configurations via registry writes. Returns updated [SystemSetting[]]
    with ImportStatus.
.OUTPUTS
    [SystemSetting[]]
#>

function Import-AccessibilitySettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [SystemSetting[]]$Settings
    )

    Write-MigrationLog -Message "Starting accessibility settings import" -Level Info

    $accessibilityDir = Join-Path $PackagePath "AccessibilitySettings"
    if (-not (Test-Path $accessibilityDir)) {
        Write-MigrationLog -Message "AccessibilitySettings directory not found at $accessibilityDir" -Level Warning
        foreach ($s in $Settings) {
            $s.ImportStatus = 'Skipped'
            if (-not $s.Data) { $s.Data = @{} }
            $s.Data['ImportNote'] = 'Export directory not found'
        }
        return $Settings
    }

    foreach ($setting in $Settings) {
        if (-not $setting.Selected) {
            $setting.ImportStatus = 'Skipped'
            Write-MigrationLog -Message "Skipping accessibility setting '$($setting.Name)' (not selected)" -Level Debug
            continue
        }

        switch ($setting.Name) {

            'StickyKeys' {
                try {
                    $regPath = 'HKCU:\Control Panel\Accessibility\StickyKeys'
                    if (-not (Test-Path $regPath)) {
                        New-Item -Path $regPath -Force | Out-Null
                    }

                    $values = $setting.Data['Values']
                    if ($values -and $values.Count -gt 0) {
                        foreach ($key in $values.Keys) {
                            Set-ItemProperty -Path $regPath -Name $key -Value $values[$key] -Force -ErrorAction Stop
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportNote'] = "Restored $($values.Count) StickyKeys values"
                    Write-MigrationLog -Message "StickyKeys settings restored successfully" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import StickyKeys: $($_.Exception.Message)" -Level Error
                }
            }

            'FilterKeys' {
                try {
                    $regPath = 'HKCU:\Control Panel\Accessibility\FilterKeys'
                    if (-not (Test-Path $regPath)) {
                        New-Item -Path $regPath -Force | Out-Null
                    }

                    $values = $setting.Data['Values']
                    if ($values -and $values.Count -gt 0) {
                        foreach ($key in $values.Keys) {
                            Set-ItemProperty -Path $regPath -Name $key -Value $values[$key] -Force -ErrorAction Stop
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportNote'] = "Restored $($values.Count) FilterKeys values"
                    Write-MigrationLog -Message "FilterKeys settings restored successfully" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import FilterKeys: $($_.Exception.Message)" -Level Error
                }
            }

            'ToggleKeys' {
                try {
                    $regPath = 'HKCU:\Control Panel\Accessibility\ToggleKeys'
                    if (-not (Test-Path $regPath)) {
                        New-Item -Path $regPath -Force | Out-Null
                    }

                    $values = $setting.Data['Values']
                    if ($values -and $values.Count -gt 0) {
                        foreach ($key in $values.Keys) {
                            Set-ItemProperty -Path $regPath -Name $key -Value $values[$key] -Force -ErrorAction Stop
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportNote'] = "Restored $($values.Count) ToggleKeys values"
                    Write-MigrationLog -Message "ToggleKeys settings restored successfully" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import ToggleKeys: $($_.Exception.Message)" -Level Error
                }
            }

            'MouseKeys' {
                try {
                    $regPath = 'HKCU:\Control Panel\Accessibility\MouseKeys'
                    if (-not (Test-Path $regPath)) {
                        New-Item -Path $regPath -Force | Out-Null
                    }

                    $values = $setting.Data['Values']
                    if ($values -and $values.Count -gt 0) {
                        foreach ($key in $values.Keys) {
                            Set-ItemProperty -Path $regPath -Name $key -Value $values[$key] -Force -ErrorAction Stop
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportNote'] = "Restored $($values.Count) MouseKeys values"
                    Write-MigrationLog -Message "MouseKeys settings restored successfully" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import MouseKeys: $($_.Exception.Message)" -Level Error
                }
            }

            'HighContrast' {
                try {
                    $regPath = 'HKCU:\Control Panel\Accessibility\HighContrast'
                    if (-not (Test-Path $regPath)) {
                        New-Item -Path $regPath -Force | Out-Null
                    }

                    $values = $setting.Data['Values']
                    if ($values -and $values.Count -gt 0) {
                        foreach ($key in $values.Keys) {
                            Set-ItemProperty -Path $regPath -Name $key -Value $values[$key] -Force -ErrorAction Stop
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportNote'] = "Restored $($values.Count) HighContrast values. A sign-out may be required for full effect."
                    Write-MigrationLog -Message "HighContrast settings restored successfully" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import HighContrast: $($_.Exception.Message)" -Level Error
                }
            }

            'Narrator' {
                try {
                    $restoredCount = 0

                    # Restore primary Narrator settings
                    $narratorPath = 'HKCU:\SOFTWARE\Microsoft\Narrator'
                    $narratorSettings = $setting.Data['NarratorSettings']
                    if ($narratorSettings -and $narratorSettings.Count -gt 0) {
                        if (-not (Test-Path $narratorPath)) {
                            New-Item -Path $narratorPath -Force | Out-Null
                        }
                        foreach ($key in $narratorSettings.Keys) {
                            Set-ItemProperty -Path $narratorPath -Name $key -Value $narratorSettings[$key] -Force -ErrorAction SilentlyContinue
                            $restoredCount++
                        }
                    }

                    # Restore NoRoam settings
                    $narratorNoRoamPath = 'HKCU:\SOFTWARE\Microsoft\Narrator\NoRoam'
                    $noRoamSettings = $setting.Data['NarratorNoRoam']
                    if ($noRoamSettings -and $noRoamSettings.Count -gt 0) {
                        if (-not (Test-Path $narratorNoRoamPath)) {
                            New-Item -Path $narratorNoRoamPath -Force | Out-Null
                        }
                        foreach ($key in $noRoamSettings.Keys) {
                            Set-ItemProperty -Path $narratorNoRoamPath -Name $key -Value $noRoamSettings[$key] -Force -ErrorAction SilentlyContinue
                            $restoredCount++
                        }
                    }

                    # Restore general accessibility features
                    $accessibilityPath = 'HKCU:\SOFTWARE\Microsoft\Accessibility'
                    $accessibilityFeatures = $setting.Data['AccessibilityFeatures']
                    if ($accessibilityFeatures -and $accessibilityFeatures.Count -gt 0) {
                        if (-not (Test-Path $accessibilityPath)) {
                            New-Item -Path $accessibilityPath -Force | Out-Null
                        }
                        foreach ($key in $accessibilityFeatures.Keys) {
                            Set-ItemProperty -Path $accessibilityPath -Name $key -Value $accessibilityFeatures[$key] -Force -ErrorAction SilentlyContinue
                            $restoredCount++
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportNote'] = "Restored $restoredCount Narrator/Accessibility values"
                    Write-MigrationLog -Message "Narrator settings restored ($restoredCount values)" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import Narrator settings: $($_.Exception.Message)" -Level Error
                }
            }

            'Magnifier' {
                try {
                    $restoredCount = 0

                    # Restore Magnifier settings
                    $magnifierPath = 'HKCU:\SOFTWARE\Microsoft\ScreenMagnifier'
                    $magnifierSettings = $setting.Data['MagnifierSettings']
                    if ($magnifierSettings -and $magnifierSettings.Count -gt 0) {
                        if (-not (Test-Path $magnifierPath)) {
                            New-Item -Path $magnifierPath -Force | Out-Null
                        }
                        foreach ($key in $magnifierSettings.Keys) {
                            Set-ItemProperty -Path $magnifierPath -Name $key -Value $magnifierSettings[$key] -Force -ErrorAction SilentlyContinue
                            $restoredCount++
                        }
                    }

                    # Restore NT Accessibility settings
                    $ntAccessPath = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Accessibility'
                    $ntAccessSettings = $setting.Data['NTAccessibility']
                    if ($ntAccessSettings -and $ntAccessSettings.Count -gt 0) {
                        if (-not (Test-Path $ntAccessPath)) {
                            New-Item -Path $ntAccessPath -Force | Out-Null
                        }
                        foreach ($key in $ntAccessSettings.Keys) {
                            Set-ItemProperty -Path $ntAccessPath -Name $key -Value $ntAccessSettings[$key] -Force -ErrorAction SilentlyContinue
                            $restoredCount++
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportNote'] = "Restored $restoredCount Magnifier values"
                    Write-MigrationLog -Message "Magnifier settings restored ($restoredCount values)" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import Magnifier settings: $($_.Exception.Message)" -Level Error
                }
            }

            default {
                $setting.ImportStatus = 'Skipped'
                if (-not $setting.Data) { $setting.Data = @{} }
                $setting.Data['ImportNote'] = "Unknown accessibility setting type: $($setting.Name)"
                Write-MigrationLog -Message "Unknown accessibility setting '$($setting.Name)' -- skipping" -Level Warning
            }
        }
    }

    $successCount = ($Settings | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Accessibility settings import complete: $successCount/$($Settings.Count) succeeded" -Level Success

    return $Settings
}
