<#
========================================================================================================
    Title:          Win11Migrator - Input Settings Importer
    Filename:       Import-InputSettings.ps1
    Description:    Restores keyboard and mouse input settings on the target machine.
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
    Restores keyboard and mouse input settings on the target machine.
.DESCRIPTION
    Reads exported keyboard and mouse settings from the migration package
    and restores them via Set-ItemProperty to the Control Panel registry
    keys. Returns updated [SystemSetting[]] with ImportStatus.
.OUTPUTS
    [SystemSetting[]]
#>

function Import-InputSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [SystemSetting[]]$Settings
    )

    Write-MigrationLog -Message "Starting input settings import" -Level Info

    $inputDir = Join-Path $PackagePath "InputSettings"
    if (-not (Test-Path $inputDir)) {
        Write-MigrationLog -Message "InputSettings directory not found at $inputDir" -Level Warning
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
            Write-MigrationLog -Message "Skipping input setting '$($setting.Name)' (not selected)" -Level Debug
            continue
        }

        switch ($setting.Name) {

            'KeyboardSettings' {
                try {
                    $regPath = 'HKCU:\Control Panel\Keyboard'
                    if (-not (Test-Path $regPath)) {
                        New-Item -Path $regPath -Force | Out-Null
                    }

                    $values = $setting.Data['Values']
                    $restoredCount = 0
                    $failedCount   = 0

                    if ($values -and $values.Count -gt 0) {
                        foreach ($key in $values.Keys) {
                            try {
                                Set-ItemProperty -Path $regPath -Name $key -Value $values[$key] -Force -ErrorAction Stop
                                $restoredCount++
                            }
                            catch {
                                $failedCount++
                                Write-MigrationLog -Message "Could not restore keyboard value '$key': $($_.Exception.Message)" -Level Debug
                            }
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['RestoredCount'] = $restoredCount
                    $setting.Data['FailedCount']   = $failedCount
                    $setting.Data['ImportNote']     = "Restored $restoredCount keyboard values. A sign-out may be required for full effect."
                    Write-MigrationLog -Message "Keyboard settings import: $restoredCount restored, $failedCount failed" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import keyboard settings: $($_.Exception.Message)" -Level Error
                }
            }

            'MouseSettings' {
                try {
                    $regPath = 'HKCU:\Control Panel\Mouse'
                    if (-not (Test-Path $regPath)) {
                        New-Item -Path $regPath -Force | Out-Null
                    }

                    $values = $setting.Data['Values']
                    $restoredCount = 0
                    $failedCount   = 0

                    if ($values -and $values.Count -gt 0) {
                        foreach ($key in $values.Keys) {
                            try {
                                Set-ItemProperty -Path $regPath -Name $key -Value $values[$key] -Force -ErrorAction Stop
                                $restoredCount++
                            }
                            catch {
                                $failedCount++
                                Write-MigrationLog -Message "Could not restore mouse value '$key': $($_.Exception.Message)" -Level Debug
                            }
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['RestoredCount'] = $restoredCount
                    $setting.Data['FailedCount']   = $failedCount
                    $setting.Data['ImportNote']     = "Restored $restoredCount mouse values. A sign-out may be required for full effect."
                    Write-MigrationLog -Message "Mouse settings import: $restoredCount restored, $failedCount failed" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import mouse settings: $($_.Exception.Message)" -Level Error
                }
            }

            default {
                $setting.ImportStatus = 'Skipped'
                if (-not $setting.Data) { $setting.Data = @{} }
                $setting.Data['ImportNote'] = "Unknown input setting type: $($setting.Name)"
                Write-MigrationLog -Message "Unknown input setting '$($setting.Name)' -- skipping" -Level Warning
            }
        }
    }

    $successCount = ($Settings | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Input settings import complete: $successCount/$($Settings.Count) succeeded" -Level Success

    return $Settings
}
