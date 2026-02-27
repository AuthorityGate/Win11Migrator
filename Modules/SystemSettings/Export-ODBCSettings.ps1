<#
========================================================================================================
    Title:          Win11Migrator - ODBC Settings Exporter
    Filename:       Export-ODBCSettings.ps1
    Description:    Exports user-level ODBC Data Source Names (DSNs) for migration.
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
    Exports user ODBC DSN configurations.
.DESCRIPTION
    Reads user-level ODBC Data Source Names from the registry at
    HKCU:\SOFTWARE\ODBC\ODBC.INI and via Get-OdbcDsn (if available).
    Returns [SystemSetting[]] with Category='ODBC'.
.OUTPUTS
    [SystemSetting[]]
#>

function Export-ODBCSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    Write-MigrationLog -Message "Starting ODBC settings export" -Level Info

    [SystemSetting[]]$results = @()

    # Ensure the output directory exists
    $odbcDir = Join-Path $ExportPath "ODBCSettings"
    if (-not (Test-Path $odbcDir)) {
        New-Item -Path $odbcDir -ItemType Directory -Force | Out-Null
    }

    # ----------------------------------------------------------------
    # 1. Registry-based user DSNs
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting ODBC user DSNs from registry" -Level Debug

        $odbcIniPath = 'HKCU:\SOFTWARE\ODBC\ODBC.INI'
        $userDSNs = @()

        if (Test-Path $odbcIniPath) {
            # Read the ODBC Data Sources list
            $dataSourcesPath = Join-Path $odbcIniPath 'ODBC Data Sources'
            $dsnNames = @()

            if (Test-Path $dataSourcesPath) {
                $dsProps = Get-ItemProperty -Path $dataSourcesPath -ErrorAction SilentlyContinue
                if ($dsProps) {
                    foreach ($p in $dsProps.PSObject.Properties) {
                        if ($p.Name -notmatch '^PS') {
                            $dsnNames += @{
                                Name   = $p.Name
                                Driver = $p.Value
                            }
                        }
                    }
                }
            }

            # Read each DSN's configuration
            foreach ($dsn in $dsnNames) {
                $dsnPath = Join-Path $odbcIniPath $dsn.Name
                $dsnConfig = @{
                    Name   = $dsn.Name
                    Driver = $dsn.Driver
                    Values = @{}
                }

                if (Test-Path $dsnPath) {
                    $dsnProps = Get-ItemProperty -Path $dsnPath -ErrorAction SilentlyContinue
                    if ($dsnProps) {
                        foreach ($p in $dsnProps.PSObject.Properties) {
                            if ($p.Name -notmatch '^PS') {
                                $dsnConfig.Values[$p.Name] = $p.Value
                            }
                        }
                    }
                }

                $userDSNs += $dsnConfig
            }

            Write-MigrationLog -Message "Found $($userDSNs.Count) user DSN(s) in registry" -Level Debug
        }
        else {
            Write-MigrationLog -Message "ODBC.INI registry key not found" -Level Debug
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'ODBC'
        $setting.Name         = 'RegistryDSNs'
        $setting.Data         = @{
            DSNs         = $userDSNs
            Count        = $userDSNs.Count
            Source       = 'Registry'
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported $($userDSNs.Count) registry-based user DSN(s)" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'ODBC'
        $setting.Name         = 'RegistryDSNs'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export ODBC registry DSNs: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 2. Get-OdbcDsn cmdlet (if available)
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Attempting ODBC export via Get-OdbcDsn cmdlet" -Level Debug

        $cmdletDSNs = @()

        if (Get-Command Get-OdbcDsn -ErrorAction SilentlyContinue) {
            try {
                $odbcDsns = Get-OdbcDsn -DsnType User -ErrorAction Stop

                foreach ($dsn in $odbcDsns) {
                    $dsnInfo = @{
                        Name       = $dsn.Name
                        DsnType    = [string]$dsn.DsnType
                        DriverName = $dsn.DriverName
                        Platform   = [string]$dsn.Platform
                        Attribute  = @{}
                    }

                    # Capture all attributes
                    if ($dsn.Attribute) {
                        foreach ($key in $dsn.Attribute.Keys) {
                            $dsnInfo.Attribute[$key] = $dsn.Attribute[$key]
                        }
                    }

                    $cmdletDSNs += $dsnInfo
                }

                Write-MigrationLog -Message "Found $($cmdletDSNs.Count) user DSN(s) via Get-OdbcDsn" -Level Debug
            }
            catch {
                Write-MigrationLog -Message "Get-OdbcDsn failed: $($_.Exception.Message)" -Level Warning
            }
        }
        else {
            Write-MigrationLog -Message "Get-OdbcDsn cmdlet not available" -Level Debug
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'ODBC'
        $setting.Name         = 'CmdletDSNs'
        $setting.Data         = @{
            DSNs   = $cmdletDSNs
            Count  = $cmdletDSNs.Count
            Source = 'Get-OdbcDsn'
        }
        $setting.ExportStatus = 'Success'
        $results += $setting
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'ODBC'
        $setting.Name         = 'CmdletDSNs'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export ODBC cmdlet DSNs: $($_.Exception.Message)" -Level Error
    }

    # Save all ODBC settings to JSON
    try {
        $allData = @{}
        foreach ($r in $results) {
            $allData[$r.Name] = $r.Data
        }
        $jsonFile = Join-Path $odbcDir "ODBCSettings.json"
        $allData | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
        Write-MigrationLog -Message "Saved ODBC settings to ODBCSettings.json" -Level Debug
    }
    catch {
        Write-MigrationLog -Message "Failed to save ODBCSettings.json: $($_.Exception.Message)" -Level Warning
    }

    $successCount = ($results | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "ODBC settings export complete: $successCount/$($results.Count) succeeded" -Level Success

    return $results
}
