<#
========================================================================================================
    Title:          Win11Migrator - WiFi Profile Exporter
    Filename:       Export-WiFiProfiles.ps1
    Description:    Exports saved WiFi network profiles using netsh for migration to the target machine.
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
    Exports all saved WiFi profiles from the source machine as XML files.
.DESCRIPTION
    Uses netsh wlan to enumerate wireless profiles and export each one
    (including cleartext keys) into the migration package.  Returns an
    array of [SystemSetting] objects with Category='WiFi'.
.OUTPUTS
    [SystemSetting[]]
#>

function Export-WiFiProfiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    Write-MigrationLog -Message "Starting WiFi profile export" -Level Info

    [SystemSetting[]]$results = @()

    # Ensure the output directory exists (caller already passes the WiFi-specific path)
    $wifiDir = $ExportPath
    if (-not (Test-Path $wifiDir)) {
        New-Item -Path $wifiDir -ItemType Directory -Force | Out-Null
    }

    # Enumerate WiFi profiles
    try {
        $rawOutput = netsh wlan show profiles 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-MigrationLog -Message "netsh wlan show profiles returned exit code $LASTEXITCODE. Wireless may not be available." -Level Warning
            return $results
        }
    }
    catch {
        Write-MigrationLog -Message "Failed to enumerate WiFi profiles: $($_.Exception.Message)" -Level Error
        return $results
    }

    # Parse profile names from netsh output
    # Lines look like: "    All User Profile     : MyNetwork"
    $profileNames = @()
    foreach ($line in $rawOutput) {
        # Check for 'Profile' first (no capture group), then extract the name.
        # The capturing -match must run LAST so $Matches[1] is populated correctly.
        if ($line -match 'Profile\s' -and $line -match ':\s+(.+)$') {
            $name = $Matches[1].Trim()
            if ($name) {
                $profileNames += $name
            }
        }
    }

    if ($profileNames.Count -eq 0) {
        Write-MigrationLog -Message "No WiFi profiles found on this system" -Level Info
        return $results
    }

    Write-MigrationLog -Message "Found $($profileNames.Count) WiFi profile(s) to export" -Level Info

    foreach ($profileName in $profileNames) {
        $setting = [SystemSetting]::new()
        $setting.Category = 'WiFi'
        $setting.Name = $profileName
        $setting.Data = @{}

        try {
            # Export profile XML with cleartext key
            $exportOutput = netsh wlan export profile name="$profileName" folder="$wifiDir" key=clear 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "netsh export returned exit code $LASTEXITCODE : $exportOutput"
            }

            # Locate the exported XML file (netsh names it "WiFi-<ProfileName>.xml" or "Wireless Network Connection-<name>.xml")
            $exportedFile = Get-ChildItem -Path $wifiDir -Filter "*.xml" |
                Where-Object { $_.Name -match [regex]::Escape($profileName) } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1

            if ($exportedFile) {
                $setting.Data['ExportedFile'] = $exportedFile.Name
                $setting.Data['FileSizeBytes'] = $exportedFile.Length
                $setting.ExportStatus = 'Success'
                Write-MigrationLog -Message "Exported WiFi profile: $profileName -> $($exportedFile.Name)" -Level Debug
            }
            else {
                # If we cannot match by name, take the most recently written XML as fallback
                $latestXml = Get-ChildItem -Path $wifiDir -Filter "*.xml" |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1
                if ($latestXml) {
                    $setting.Data['ExportedFile'] = $latestXml.Name
                    $setting.Data['FileSizeBytes'] = $latestXml.Length
                    $setting.ExportStatus = 'Success'
                    Write-MigrationLog -Message "Exported WiFi profile: $profileName (matched to $($latestXml.Name))" -Level Debug
                }
                else {
                    throw "Export command succeeded but no XML file was produced"
                }
            }
        }
        catch {
            $setting.ExportStatus = 'Failed'
            $setting.Data['Error'] = $_.Exception.Message
            Write-MigrationLog -Message "Failed to export WiFi profile '$profileName': $($_.Exception.Message)" -Level Error
        }

        $results += $setting
    }

    $successCount = ($results | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "WiFi profile export complete: $successCount/$($results.Count) succeeded" -Level Success

    return $results
}
