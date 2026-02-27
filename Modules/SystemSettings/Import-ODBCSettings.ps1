<#
========================================================================================================
    Title:          Win11Migrator - ODBC Settings Importer
    Filename:       Import-ODBCSettings.ps1
    Description:    Restores user-level ODBC Data Source Names (DSNs) on the target machine.
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
    Restores user ODBC DSN configurations on the target machine.
.DESCRIPTION
    Reads exported ODBC DSN settings from the migration package and restores
    them via Set-OdbcDsn/Add-OdbcDsn cmdlets or direct registry writes.
    Returns updated [SystemSetting[]] with ImportStatus.
.OUTPUTS
    [SystemSetting[]]
#>

function Import-ODBCSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [SystemSetting[]]$Settings
    )

    Write-MigrationLog -Message "Starting ODBC settings import" -Level Info

    $odbcDir = Join-Path $PackagePath "ODBCSettings"
    if (-not (Test-Path $odbcDir)) {
        Write-MigrationLog -Message "ODBCSettings directory not found at $odbcDir" -Level Warning
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
            Write-MigrationLog -Message "Skipping ODBC setting '$($setting.Name)' (not selected)" -Level Debug
            continue
        }

        switch ($setting.Name) {

            'RegistryDSNs' {
                try {
                    $dsns = $setting.Data['DSNs']
                    $restoredCount = 0
                    $failedCount   = 0

                    if ($dsns -and $dsns.Count -gt 0) {
                        $odbcIniPath = 'HKCU:\SOFTWARE\ODBC\ODBC.INI'

                        # Ensure base registry path exists
                        if (-not (Test-Path $odbcIniPath)) {
                            New-Item -Path $odbcIniPath -Force | Out-Null
                        }

                        # Ensure ODBC Data Sources key exists
                        $dataSourcesPath = Join-Path $odbcIniPath 'ODBC Data Sources'
                        if (-not (Test-Path $dataSourcesPath)) {
                            New-Item -Path $dataSourcesPath -Force | Out-Null
                        }

                        foreach ($dsn in $dsns) {
                            try {
                                # Register the DSN name and driver in the Data Sources list
                                Set-ItemProperty -Path $dataSourcesPath -Name $dsn.Name -Value $dsn.Driver -Force -ErrorAction Stop

                                # Create the DSN configuration key
                                $dsnPath = Join-Path $odbcIniPath $dsn.Name
                                if (-not (Test-Path $dsnPath)) {
                                    New-Item -Path $dsnPath -Force | Out-Null
                                }

                                # Restore all configuration values
                                $values = $dsn.Values
                                if ($values) {
                                    foreach ($key in $values.Keys) {
                                        Set-ItemProperty -Path $dsnPath -Name $key -Value $values[$key] -Force -ErrorAction SilentlyContinue
                                    }
                                }

                                $restoredCount++
                                Write-MigrationLog -Message "Restored ODBC DSN: $($dsn.Name) (Driver: $($dsn.Driver))" -Level Debug
                            }
                            catch {
                                $failedCount++
                                Write-MigrationLog -Message "Failed to restore DSN '$($dsn.Name)': $($_.Exception.Message)" -Level Warning
                            }
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['RestoredCount'] = $restoredCount
                    $setting.Data['FailedCount']   = $failedCount
                    $setting.Data['ImportNote']     = "Restored $restoredCount/$($dsns.Count) registry DSN(s). Ensure matching ODBC drivers are installed on this machine."
                    Write-MigrationLog -Message "Registry DSN import: $restoredCount restored, $failedCount failed" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import registry DSNs: $($_.Exception.Message)" -Level Error
                }
            }

            'CmdletDSNs' {
                try {
                    $dsns = $setting.Data['DSNs']
                    $restoredCount = 0
                    $failedCount   = 0

                    if ($dsns -and $dsns.Count -gt 0) {
                        $hasCmdlet = $null -ne (Get-Command Add-OdbcDsn -ErrorAction SilentlyContinue)

                        foreach ($dsn in $dsns) {
                            try {
                                if ($hasCmdlet) {
                                    # Check if DSN already exists
                                    $existing = Get-OdbcDsn -Name $dsn.Name -DsnType User -ErrorAction SilentlyContinue
                                    if ($existing) {
                                        # Update existing DSN
                                        if ($dsn.Attribute -and $dsn.Attribute.Count -gt 0) {
                                            Set-OdbcDsn -Name $dsn.Name -DsnType User -SetPropertyValue ($dsn.Attribute.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -ErrorAction Stop
                                        }
                                    }
                                    else {
                                        # Add new DSN
                                        $addParams = @{
                                            Name       = $dsn.Name
                                            DsnType    = 'User'
                                            DriverName = $dsn.DriverName
                                            ErrorAction = 'Stop'
                                        }
                                        if ($dsn.Attribute -and $dsn.Attribute.Count -gt 0) {
                                            $addParams['SetPropertyValue'] = $dsn.Attribute.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
                                        }
                                        Add-OdbcDsn @addParams
                                    }
                                }
                                else {
                                    # Fallback to registry writes
                                    $odbcIniPath = 'HKCU:\SOFTWARE\ODBC\ODBC.INI'
                                    $dataSourcesPath = Join-Path $odbcIniPath 'ODBC Data Sources'

                                    if (-not (Test-Path $dataSourcesPath)) {
                                        New-Item -Path $dataSourcesPath -Force | Out-Null
                                    }
                                    Set-ItemProperty -Path $dataSourcesPath -Name $dsn.Name -Value $dsn.DriverName -Force

                                    $dsnPath = Join-Path $odbcIniPath $dsn.Name
                                    if (-not (Test-Path $dsnPath)) {
                                        New-Item -Path $dsnPath -Force | Out-Null
                                    }

                                    if ($dsn.Attribute) {
                                        foreach ($key in $dsn.Attribute.Keys) {
                                            Set-ItemProperty -Path $dsnPath -Name $key -Value $dsn.Attribute[$key] -Force -ErrorAction SilentlyContinue
                                        }
                                    }
                                }

                                $restoredCount++
                                Write-MigrationLog -Message "Restored ODBC DSN via cmdlet: $($dsn.Name)" -Level Debug
                            }
                            catch {
                                $failedCount++
                                Write-MigrationLog -Message "Failed to restore cmdlet DSN '$($dsn.Name)': $($_.Exception.Message)" -Level Warning
                            }
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['RestoredCount'] = $restoredCount
                    $setting.Data['FailedCount']   = $failedCount
                    $setting.Data['ImportNote']     = "Restored $restoredCount/$($dsns.Count) cmdlet DSN(s)"
                    Write-MigrationLog -Message "Cmdlet DSN import: $restoredCount restored, $failedCount failed" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import cmdlet DSNs: $($_.Exception.Message)" -Level Error
                }
            }

            default {
                $setting.ImportStatus = 'Skipped'
                if (-not $setting.Data) { $setting.Data = @{} }
                $setting.Data['ImportNote'] = "Unknown ODBC setting type: $($setting.Name)"
                Write-MigrationLog -Message "Unknown ODBC setting '$($setting.Name)' -- skipping" -Level Warning
            }
        }
    }

    $successCount = ($Settings | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "ODBC settings import complete: $successCount/$($Settings.Count) succeeded" -Level Success

    return $Settings
}
