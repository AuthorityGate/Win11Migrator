<#
========================================================================================================
    Title:          Win11Migrator - Folder Options Importer
    Filename:       Import-FolderOptions.ps1
    Description:    Restores Windows Explorer folder view options and preferences on the target machine.
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
    Restores Windows Explorer folder options on the target machine.
.DESCRIPTION
    Reads exported folder view preferences from the migration package and
    restores them via Set-ItemProperty to the Explorer\Advanced and
    CabinetState registry keys. Returns updated [SystemSetting[]] with
    ImportStatus.
.OUTPUTS
    [SystemSetting[]]
#>

function Import-FolderOptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [SystemSetting[]]$Settings
    )

    Write-MigrationLog -Message "Starting folder options import" -Level Info

    $folderDir = Join-Path $PackagePath "FolderOptions"
    if (-not (Test-Path $folderDir)) {
        Write-MigrationLog -Message "FolderOptions directory not found at $folderDir" -Level Warning
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
            Write-MigrationLog -Message "Skipping folder option '$($setting.Name)' (not selected)" -Level Debug
            continue
        }

        switch ($setting.Name) {

            'ExplorerAdvanced' {
                try {
                    $regPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
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
                                Write-MigrationLog -Message "Could not restore Explorer Advanced value '$key': $($_.Exception.Message)" -Level Debug
                            }
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['RestoredCount'] = $restoredCount
                    $setting.Data['FailedCount']   = $failedCount
                    $setting.Data['ImportNote']     = "Restored $restoredCount Explorer Advanced values. Explorer may need to be restarted for changes to take effect."
                    Write-MigrationLog -Message "Explorer Advanced import: $restoredCount restored, $failedCount failed" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import Explorer Advanced settings: $($_.Exception.Message)" -Level Error
                }
            }

            'CabinetState' {
                try {
                    $regPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\CabinetState'
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
                                Write-MigrationLog -Message "Could not restore CabinetState value '$key': $($_.Exception.Message)" -Level Debug
                            }
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['RestoredCount'] = $restoredCount
                    $setting.Data['FailedCount']   = $failedCount
                    $setting.Data['ImportNote']     = "Restored $restoredCount CabinetState values"
                    Write-MigrationLog -Message "CabinetState import: $restoredCount restored, $failedCount failed" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import CabinetState settings: $($_.Exception.Message)" -Level Error
                }
            }

            default {
                $setting.ImportStatus = 'Skipped'
                if (-not $setting.Data) { $setting.Data = @{} }
                $setting.Data['ImportNote'] = "Unknown folder option type: $($setting.Name)"
                Write-MigrationLog -Message "Unknown folder option '$($setting.Name)' -- skipping" -Level Warning
            }
        }
    }

    $successCount = ($Settings | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Folder options import complete: $successCount/$($Settings.Count) succeeded" -Level Success

    return $Settings
}
