<#
========================================================================================================
    Title:          Win11Migrator - VPN Connections Exporter
    Filename:       Export-VPNConnections.ps1
    Description:    Exports Windows built-in VPN connections and phonebook files for migration.
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
    Exports Windows VPN connection configurations.
.DESCRIPTION
    Captures built-in Windows VPN connections via Get-VpnConnection and copies
    the rasphone.pbk phonebook file for complete VPN profile restoration.
    Returns [SystemSetting[]] with Category='VPN'.
.OUTPUTS
    [SystemSetting[]]
#>

function Export-VPNConnections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    Write-MigrationLog -Message "Starting VPN connections export" -Level Info

    [SystemSetting[]]$results = @()

    # Ensure the output directory exists
    $vpnDir = Join-Path $ExportPath "VPNConnections"
    if (-not (Test-Path $vpnDir)) {
        New-Item -Path $vpnDir -ItemType Directory -Force | Out-Null
    }

    # ----------------------------------------------------------------
    # 1. Built-in Windows VPN connections
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting Windows VPN connections" -Level Debug

        $vpnConnections = @()

        if (Get-Command Get-VpnConnection -ErrorAction SilentlyContinue) {
            try {
                $vpns = Get-VpnConnection -ErrorAction Stop

                foreach ($vpn in $vpns) {
                    $vpnInfo = @{
                        Name                  = $vpn.Name
                        ServerAddress         = $vpn.ServerAddress
                        TunnelType            = [string]$vpn.TunnelType
                        AuthenticationMethod  = @($vpn.AuthenticationMethod | ForEach-Object { [string]$_ })
                        EncryptionLevel       = [string]$vpn.EncryptionLevel
                        L2tpIPsecAuth         = [string]$vpn.L2tpIPsecAuth
                        SplitTunneling        = $vpn.SplitTunneling
                        RememberCredential    = $vpn.RememberCredential
                        UseWinlogonCredential = $vpn.UseWinlogonCredential
                        DnsSuffix             = $vpn.DnsSuffix
                        IdleDisconnectSeconds = $vpn.IdleDisconnectSeconds
                        ConnectionStatus      = [string]$vpn.ConnectionStatus
                    }
                    $vpnConnections += $vpnInfo
                }

                Write-MigrationLog -Message "Found $($vpnConnections.Count) VPN connection(s)" -Level Debug
            }
            catch {
                Write-MigrationLog -Message "Get-VpnConnection failed: $($_.Exception.Message)" -Level Warning
            }
        }
        else {
            Write-MigrationLog -Message "Get-VpnConnection cmdlet not available" -Level Warning
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'VPN'
        $setting.Name         = 'VPNConnections'
        $setting.Data         = @{
            Connections  = $vpnConnections
            Count        = $vpnConnections.Count
            ExportedFile = 'VPNConnections.json'
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported $($vpnConnections.Count) VPN connection(s)" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'VPN'
        $setting.Name         = 'VPNConnections'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export VPN connections: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 2. Rasphone phonebook file (raw VPN profiles)
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting rasphone.pbk phonebook file" -Level Debug

        $pbkCopied = $false
        $pbkPaths = @(
            (Join-Path $env:APPDATA "Microsoft\Network\Connections\Pbk\rasphone.pbk"),
            (Join-Path $env:APPDATA "Microsoft\Network\Connections\Pbk\_hiddenPbk\rasphone.pbk")
        )

        $copiedFiles = @()
        foreach ($pbkPath in $pbkPaths) {
            if (Test-Path $pbkPath) {
                $destName = "rasphone_$(Split-Path (Split-Path $pbkPath -Parent) -Leaf).pbk"
                # Use a clean name for the primary pbk
                if ($destName -eq 'rasphone_Pbk.pbk') {
                    $destName = 'rasphone.pbk'
                }
                $destPath = Join-Path $vpnDir $destName
                Copy-Item -Path $pbkPath -Destination $destPath -Force -ErrorAction Stop
                $copiedFiles += $destName
                $pbkCopied = $true
                Write-MigrationLog -Message "Copied phonebook: $pbkPath" -Level Debug
            }
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'VPN'
        $setting.Name         = 'RasPhonebook'
        $setting.Data         = @{
            CopiedFiles  = $copiedFiles
            FileCount    = $copiedFiles.Count
            PbkAvailable = $pbkCopied
        }
        $setting.ExportStatus = if ($pbkCopied) { 'Success' } else { 'Success' }
        $results += $setting

        if ($pbkCopied) {
            Write-MigrationLog -Message "Exported $($copiedFiles.Count) phonebook file(s)" -Level Debug
        }
        else {
            Write-MigrationLog -Message "No rasphone.pbk phonebook files found (no VPN profiles configured via phonebook)" -Level Debug
        }
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'VPN'
        $setting.Name         = 'RasPhonebook'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export rasphone.pbk: $($_.Exception.Message)" -Level Error
    }

    # Save VPN connection data to JSON
    try {
        $allData = @{}
        foreach ($r in $results) {
            $allData[$r.Name] = $r.Data
        }
        $jsonFile = Join-Path $vpnDir "VPNConnections.json"
        $allData | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
        Write-MigrationLog -Message "Saved VPN connection data to VPNConnections.json" -Level Debug
    }
    catch {
        Write-MigrationLog -Message "Failed to save VPNConnections.json: $($_.Exception.Message)" -Level Warning
    }

    $successCount = ($results | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "VPN connections export complete: $successCount/$($results.Count) succeeded" -Level Success

    return $results
}
