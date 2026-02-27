<#
========================================================================================================
    Title:          Win11Migrator - Regional Settings Importer
    Filename:       Import-RegionalSettings.ps1
    Description:    Restores Windows regional, locale, and keyboard layout settings on the target machine.
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
    Restores Windows regional and language settings on the target machine.
.DESCRIPTION
    Reads exported regional settings from the migration package and restores
    International registry values, user language list, and keyboard layout
    configurations. Returns updated [SystemSetting[]] with ImportStatus.
.OUTPUTS
    [SystemSetting[]]
#>

function Import-RegionalSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [SystemSetting[]]$Settings
    )

    Write-MigrationLog -Message "Starting regional settings import" -Level Info

    $regionalDir = Join-Path $PackagePath "RegionalSettings"
    if (-not (Test-Path $regionalDir)) {
        Write-MigrationLog -Message "RegionalSettings directory not found at $regionalDir" -Level Warning
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
            Write-MigrationLog -Message "Skipping regional setting '$($setting.Name)' (not selected)" -Level Debug
            continue
        }

        switch ($setting.Name) {

            'InternationalSettings' {
                try {
                    $regPath = 'HKCU:\Control Panel\International'
                    if (-not (Test-Path $regPath)) {
                        New-Item -Path $regPath -Force | Out-Null
                    }

                    $values = $setting.Data['Values']
                    $restoredCount = 0

                    if ($values -and $values.Count -gt 0) {
                        foreach ($key in $values.Keys) {
                            try {
                                Set-ItemProperty -Path $regPath -Name $key -Value $values[$key] -Force -ErrorAction Stop
                                $restoredCount++
                            }
                            catch {
                                Write-MigrationLog -Message "Could not restore International value '$key': $($_.Exception.Message)" -Level Debug
                            }
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['RestoredCount'] = $restoredCount
                    $setting.Data['ImportNote'] = "Restored $restoredCount International registry values. A sign-out may be required."
                    Write-MigrationLog -Message "International settings restored ($restoredCount values)" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import International settings: $($_.Exception.Message)" -Level Error
                }
            }

            'LanguageSettings' {
                try {
                    $restoredItems = @()

                    # Restore user language list via Set-WinUserLanguageList
                    $userLangList = $setting.Data['UserLanguageList']
                    if ($userLangList -and $userLangList.Count -gt 0) {
                        if (Get-Command Set-WinUserLanguageList -ErrorAction SilentlyContinue) {
                            try {
                                $newLangList = New-WinUserLanguageList -Language $userLangList[0].LanguageTag -ErrorAction Stop
                                for ($i = 1; $i -lt $userLangList.Count; $i++) {
                                    $newLangList.Add($userLangList[$i].LanguageTag)
                                }
                                Set-WinUserLanguageList -LanguageList $newLangList -Force -ErrorAction Stop
                                $restoredItems += "UserLanguageList ($($userLangList.Count) languages)"
                            }
                            catch {
                                Write-MigrationLog -Message "Set-WinUserLanguageList failed: $($_.Exception.Message)" -Level Warning
                            }
                        }
                        else {
                            Write-MigrationLog -Message "Set-WinUserLanguageList not available on this system" -Level Warning
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportNote'] = "Restored: $($restoredItems -join ', '). System locale changes may require admin and a reboot."
                    Write-MigrationLog -Message "Language settings restored ($($restoredItems.Count) items)" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import language settings: $($_.Exception.Message)" -Level Error
                }
            }

            'KeyboardLayout' {
                try {
                    $restoredCount = 0

                    # Restore Preload registry
                    $preload = $setting.Data['Preload']
                    if ($preload -and $preload.Count -gt 0) {
                        $preloadPath = 'HKCU:\Keyboard Layout\Preload'
                        if (-not (Test-Path $preloadPath)) {
                            New-Item -Path $preloadPath -Force | Out-Null
                        }
                        foreach ($key in $preload.Keys) {
                            Set-ItemProperty -Path $preloadPath -Name $key -Value $preload[$key] -Force -ErrorAction SilentlyContinue
                            $restoredCount++
                        }
                    }

                    # Restore Substitutes registry
                    $substitutes = $setting.Data['Substitutes']
                    if ($substitutes -and $substitutes.Count -gt 0) {
                        $substitutesPath = 'HKCU:\Keyboard Layout\Substitutes'
                        if (-not (Test-Path $substitutesPath)) {
                            New-Item -Path $substitutesPath -Force | Out-Null
                        }
                        foreach ($key in $substitutes.Keys) {
                            Set-ItemProperty -Path $substitutesPath -Name $key -Value $substitutes[$key] -Force -ErrorAction SilentlyContinue
                            $restoredCount++
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['RestoredCount'] = $restoredCount
                    $setting.Data['ImportNote'] = "Restored $restoredCount keyboard layout values. A sign-out may be required."
                    Write-MigrationLog -Message "Keyboard layout restored ($restoredCount values)" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import keyboard layout: $($_.Exception.Message)" -Level Error
                }
            }

            default {
                $setting.ImportStatus = 'Skipped'
                if (-not $setting.Data) { $setting.Data = @{} }
                $setting.Data['ImportNote'] = "Unknown regional setting type: $($setting.Name)"
                Write-MigrationLog -Message "Unknown regional setting '$($setting.Name)' -- skipping" -Level Warning
            }
        }
    }

    $successCount = ($Settings | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Regional settings import complete: $successCount/$($Settings.Count) succeeded" -Level Success

    return $Settings
}
