<#
========================================================================================================
    Title:          Win11Migrator - Environment Variable Exporter
    Filename:       Export-EnvironmentVariables.ps1
    Description:    Exports user and system environment variables for migration.
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
    Exports user-level environment variables from the source machine.
.DESCRIPTION
    Reads all user-scoped environment variables via
    [System.Environment]::GetEnvironmentVariables('User').
    The PATH variable is exported separately so it can be merged (rather
    than overwritten) during import.  Returns [SystemSetting[]] with
    Category='EnvVar'.
.OUTPUTS
    [SystemSetting[]]
#>

function Export-EnvironmentVariables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    Write-MigrationLog -Message "Starting environment variable export" -Level Info

    [SystemSetting[]]$results = @()

    try {
        $userVars = [System.Environment]::GetEnvironmentVariables('User')
    }
    catch {
        Write-MigrationLog -Message "Failed to read user environment variables: $($_.Exception.Message)" -Level Error
        return $results
    }

    if (-not $userVars -or $userVars.Count -eq 0) {
        Write-MigrationLog -Message "No user-level environment variables found" -Level Info
        return $results
    }

    Write-MigrationLog -Message "Found $($userVars.Count) user-level environment variable(s)" -Level Info

    foreach ($key in $userVars.Keys) {
        $value = $userVars[$key]

        $setting = [SystemSetting]::new()
        $setting.Category = 'EnvVar'
        $setting.Data = @{}

        try {
            if ($key -ieq 'Path') {
                # Export PATH separately with individual entries for merge logic
                $setting.Name = 'PATH'
                $pathEntries = $value -split ';' | Where-Object { $_.Trim() -ne '' }
                $setting.Data['VariableName'] = 'Path'
                $setting.Data['Value']        = $value
                $setting.Data['PathEntries']  = $pathEntries
                $setting.Data['IsPath']       = $true
                $setting.Data['EntryCount']   = $pathEntries.Count

                Write-MigrationLog -Message "Exported PATH with $($pathEntries.Count) entries" -Level Debug
            }
            else {
                $setting.Name = $key
                $setting.Data['VariableName'] = $key
                $setting.Data['Value']        = $value
                $setting.Data['IsPath']       = $false

                Write-MigrationLog -Message "Exported environment variable: $key" -Level Debug
            }

            $setting.ExportStatus = 'Success'
        }
        catch {
            $setting.Name = $key
            $setting.ExportStatus = 'Failed'
            $setting.Data['Error'] = $_.Exception.Message
            Write-MigrationLog -Message "Failed to export environment variable '$key': $($_.Exception.Message)" -Level Error
        }

        $results += $setting
    }

    $successCount = ($results | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Environment variable export complete: $successCount/$($results.Count) succeeded" -Level Success

    return $results
}
