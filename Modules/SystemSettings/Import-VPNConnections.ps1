<#
========================================================================================================
    Title:          Win11Migrator - VPN Connections Importer
    Filename:       Import-VPNConnections.ps1
    Description:    Restores Windows built-in VPN connections and phonebook files on the target machine.
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
    Restores Windows VPN connections on the target machine.
.DESCRIPTION
    Reads exported VPN configurations from the migration package and restores
    them via Add-VpnConnection and by copying back the rasphone.pbk phonebook
    file. Returns updated [SystemSetting[]] with ImportStatus.
.OUTPUTS
    [SystemSetting[]]
#>

function Import-VPNConnections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [SystemSetting[]]$Settings
    )

    Write-MigrationLog -Message "Starting VPN connections import" -Level Info

    $vpnDir = Join-Path $PackagePath "VPNConnections"
    if (-not (Test-Path $vpnDir)) {
        Write-MigrationLog -Message "VPNConnections directory not found at $vpnDir" -Level Warning
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
            Write-MigrationLog -Message "Skipping VPN setting '$($setting.Name)' (not selected)" -Level Debug
            continue
        }

        switch ($setting.Name) {

            'VPNConnections' {
                try {
                    $connections = $setting.Data['Connections']
                    $restoredCount = 0
                    $failedCount   = 0

                    if ($connections -and $connections.Count -gt 0) {
                        if (-not (Get-Command Add-VpnConnection -ErrorAction SilentlyContinue)) {
                            throw "Add-VpnConnection cmdlet not available on this system"
                        }

                        foreach ($vpn in $connections) {
                            try {
                                # Check if VPN already exists
                                $existing = Get-VpnConnection -Name $vpn.Name -ErrorAction SilentlyContinue
                                if ($existing) {
                                    Write-MigrationLog -Message "VPN '$($vpn.Name)' already exists, skipping" -Level Debug
                                    $restoredCount++
                                    continue
                                }

                                # Build parameters for Add-VpnConnection
                                $addParams = @{
                                    Name               = $vpn.Name
                                    ServerAddress      = $vpn.ServerAddress
                                    TunnelType         = $vpn.TunnelType
                                    EncryptionLevel    = $vpn.EncryptionLevel
                                    SplitTunneling     = $vpn.SplitTunneling
                                    RememberCredential = $vpn.RememberCredential
                                    Force              = $true
                                    ErrorAction        = 'Stop'
                                }

                                # Set authentication method if available
                                if ($vpn.AuthenticationMethod -and $vpn.AuthenticationMethod.Count -gt 0) {
                                    $addParams['AuthenticationMethod'] = $vpn.AuthenticationMethod[0]
                                }

                                # Set L2TP pre-shared key auth if applicable
                                if ($vpn.TunnelType -eq 'L2tp' -and $vpn.L2tpIPsecAuth) {
                                    $addParams['L2tpPsk'] = ''  # PSK cannot be exported; user must re-enter
                                }

                                # Set DNS suffix if available
                                if ($vpn.DnsSuffix) {
                                    $addParams['DnsSuffix'] = $vpn.DnsSuffix
                                }

                                # Set idle disconnect if available
                                if ($vpn.IdleDisconnectSeconds -and $vpn.IdleDisconnectSeconds -gt 0) {
                                    $addParams['IdleDisconnectSeconds'] = $vpn.IdleDisconnectSeconds
                                }

                                Add-VpnConnection @addParams
                                $restoredCount++
                                Write-MigrationLog -Message "Restored VPN connection: $($vpn.Name)" -Level Debug
                            }
                            catch {
                                $failedCount++
                                Write-MigrationLog -Message "Failed to restore VPN '$($vpn.Name)': $($_.Exception.Message)" -Level Warning
                            }
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['RestoredCount'] = $restoredCount
                    $setting.Data['FailedCount']   = $failedCount
                    $setting.Data['ImportNote']     = "Restored $restoredCount/$($connections.Count) VPN connections. Credentials (passwords, pre-shared keys) must be re-entered manually."
                    Write-MigrationLog -Message "VPN connections import: $restoredCount restored, $failedCount failed" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import VPN connections: $($_.Exception.Message)" -Level Error
                }
            }

            'RasPhonebook' {
                try {
                    $copiedFiles = $setting.Data['CopiedFiles']
                    $restoredCount = 0

                    if ($copiedFiles -and $copiedFiles.Count -gt 0) {
                        $pbkDestDir = Join-Path $env:APPDATA "Microsoft\Network\Connections\Pbk"
                        if (-not (Test-Path $pbkDestDir)) {
                            New-Item -Path $pbkDestDir -ItemType Directory -Force | Out-Null
                        }

                        foreach ($fileName in $copiedFiles) {
                            $sourcePbk = Join-Path $vpnDir $fileName
                            if (Test-Path $sourcePbk) {
                                # Determine the correct destination
                                if ($fileName -match '_hiddenPbk') {
                                    $hiddenDir = Join-Path $pbkDestDir "_hiddenPbk"
                                    if (-not (Test-Path $hiddenDir)) {
                                        New-Item -Path $hiddenDir -ItemType Directory -Force | Out-Null
                                    }
                                    $destPbk = Join-Path $hiddenDir "rasphone.pbk"
                                }
                                else {
                                    $destPbk = Join-Path $pbkDestDir "rasphone.pbk"
                                }

                                # Backup existing pbk before overwriting
                                if (Test-Path $destPbk) {
                                    $backupPath = "$destPbk.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                                    Copy-Item -Path $destPbk -Destination $backupPath -Force -ErrorAction SilentlyContinue
                                    Write-MigrationLog -Message "Backed up existing phonebook to $backupPath" -Level Debug
                                }

                                Copy-Item -Path $sourcePbk -Destination $destPbk -Force -ErrorAction Stop
                                $restoredCount++
                                Write-MigrationLog -Message "Restored phonebook file: $fileName" -Level Debug
                            }
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['RestoredFiles'] = $restoredCount
                    $setting.Data['ImportNote']    = "Restored $restoredCount phonebook file(s)"
                    Write-MigrationLog -Message "Rasphone phonebook import: $restoredCount file(s) restored" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import rasphone.pbk: $($_.Exception.Message)" -Level Error
                }
            }

            default {
                $setting.ImportStatus = 'Skipped'
                if (-not $setting.Data) { $setting.Data = @{} }
                $setting.Data['ImportNote'] = "Unknown VPN setting type: $($setting.Name)"
                Write-MigrationLog -Message "Unknown VPN setting '$($setting.Name)' -- skipping" -Level Warning
            }
        }
    }

    $successCount = ($Settings | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "VPN connections import complete: $successCount/$($Settings.Count) succeeded" -Level Success

    return $Settings
}
