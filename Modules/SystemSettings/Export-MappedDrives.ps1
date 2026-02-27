<#
========================================================================================================
    Title:          Win11Migrator - Mapped Drive Exporter
    Filename:       Export-MappedDrives.ps1
    Description:    Exports mapped network drive configurations for migration.
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
    Exports mapped network drives from the source machine.
.DESCRIPTION
    Reads persistent mapped drives from HKCU:\Network and also captures
    current-session drives via "net use".  Returns [SystemSetting[]] with
    Category='MappedDrive'.
.OUTPUTS
    [SystemSetting[]]
#>

function Export-MappedDrives {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    Write-MigrationLog -Message "Starting mapped drive export" -Level Info

    [SystemSetting[]]$results = @()

    # Track which drive letters we have already captured (to de-duplicate)
    $capturedDrives = @{}

    # --- Source 1: Persistent drives from the registry (HKCU:\Network) ---
    $networkKeyPath = 'HKCU:\Network'
    if (Test-Path $networkKeyPath) {
        try {
            $driveLetters = Get-ChildItem -Path $networkKeyPath -ErrorAction Stop

            foreach ($driveKey in $driveLetters) {
                $driveLetter = $driveKey.PSChildName
                $setting = [SystemSetting]::new()
                $setting.Category = 'MappedDrive'
                $setting.Name = "${driveLetter}:"
                $setting.Data = @{}

                try {
                    $regProps = Get-ItemProperty -Path $driveKey.PSPath -ErrorAction Stop

                    $remotePath = if ($regProps.PSObject.Properties['RemotePath']) { $regProps.RemotePath } else { '' }
                    $userName   = if ($regProps.PSObject.Properties['UserName'])   { $regProps.UserName }   else { '' }

                    $setting.Data['DriveLetter'] = "${driveLetter}:"
                    $setting.Data['RemotePath']  = $remotePath
                    $setting.Data['UserName']    = $userName
                    $setting.Data['Persistent']  = $true
                    $setting.Data['Source']       = 'Registry'

                    $setting.ExportStatus = 'Success'
                    $capturedDrives[$driveLetter] = $true
                    Write-MigrationLog -Message "Exported persistent mapped drive: ${driveLetter}: -> $remotePath" -Level Debug
                }
                catch {
                    $setting.ExportStatus = 'Failed'
                    $setting.Data['Error'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to read registry data for drive ${driveLetter}: $($_.Exception.Message)" -Level Error
                }

                $results += $setting
            }
        }
        catch {
            Write-MigrationLog -Message "Failed to enumerate HKCU:\Network: $($_.Exception.Message)" -Level Error
        }
    }
    else {
        Write-MigrationLog -Message "Registry key HKCU:\Network does not exist. No persistent mapped drives." -Level Info
    }

    # --- Source 2: Current session drives via "net use" ---
    try {
        $netUseOutput = net use 2>&1
        if ($LASTEXITCODE -eq 0 -or $netUseOutput) {
            foreach ($line in $netUseOutput) {
                # Lines look like:  "OK           Z:        \\server\share     Microsoft Windows Network"
                #               or: "Disconnected Y:        \\server\share     ..."
                if ($line -match '^\s*(\S+)\s+([A-Za-z]):?\s+(\\\\[^\s]+)') {
                    $status      = $Matches[1]
                    $driveLetter = $Matches[2]
                    $remotePath  = $Matches[3]

                    # Skip if already captured from registry
                    if ($capturedDrives.ContainsKey($driveLetter)) {
                        continue
                    }

                    $setting = [SystemSetting]::new()
                    $setting.Category = 'MappedDrive'
                    $setting.Name = "${driveLetter}:"
                    $setting.Data = @{
                        DriveLetter = "${driveLetter}:"
                        RemotePath  = $remotePath
                        UserName    = ''
                        Persistent  = $false
                        Source      = 'NetUse'
                        Status      = $status
                    }
                    $setting.ExportStatus = 'Success'
                    $capturedDrives[$driveLetter] = $true

                    Write-MigrationLog -Message "Exported session mapped drive: ${driveLetter}: -> $remotePath (Status=$status)" -Level Debug
                    $results += $setting
                }
            }
        }
    }
    catch {
        Write-MigrationLog -Message "Failed to run net use: $($_.Exception.Message)" -Level Warning
    }

    if ($results.Count -eq 0) {
        Write-MigrationLog -Message "No mapped drives found on this system" -Level Info
    }
    else {
        $successCount = ($results | Where-Object { $_.ExportStatus -eq 'Success' }).Count
        Write-MigrationLog -Message "Mapped drive export complete: $successCount/$($results.Count) succeeded" -Level Success
    }

    return $results
}
