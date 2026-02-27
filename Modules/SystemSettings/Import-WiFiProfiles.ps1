<#
========================================================================================================
    Title:          Win11Migrator - WiFi Profile Importer
    Filename:       Import-WiFiProfiles.ps1
    Description:    Restores saved WiFi network profiles using netsh on the target machine.
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
    Imports WiFi profiles from the migration package onto the target machine.
.DESCRIPTION
    Reads exported XML files from the WiFi subdirectory of the migration
    package and uses netsh wlan add profile to restore each one.
    Returns updated [SystemSetting[]] with ImportStatus.
.OUTPUTS
    [SystemSetting[]]
#>

function Import-WiFiProfiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [SystemSetting[]]$Settings
    )

    Write-MigrationLog -Message "Starting WiFi profile import" -Level Info

    $wifiDir = Join-Path $PackagePath "WiFi"
    if (-not (Test-Path $wifiDir)) {
        Write-MigrationLog -Message "WiFi export directory not found at $wifiDir. Nothing to import." -Level Warning
        foreach ($s in $Settings) {
            $s.ImportStatus = 'Skipped'
            $s.Data['ImportNote'] = 'Export directory not found'
        }
        return $Settings
    }

    # Build a lookup of available XML files
    $xmlFiles = Get-ChildItem -Path $wifiDir -Filter "*.xml" -ErrorAction SilentlyContinue

    if (-not $xmlFiles -or $xmlFiles.Count -eq 0) {
        Write-MigrationLog -Message "No WiFi XML files found in $wifiDir" -Level Warning
        foreach ($s in $Settings) {
            $s.ImportStatus = 'Skipped'
            $s.Data['ImportNote'] = 'No XML files found'
        }
        return $Settings
    }

    foreach ($setting in $Settings) {
        if (-not $setting.Selected) {
            $setting.ImportStatus = 'Skipped'
            Write-MigrationLog -Message "Skipping WiFi profile '$($setting.Name)' (not selected)" -Level Debug
            continue
        }

        try {
            # Find the matching XML file
            $targetFile = $null
            if ($setting.Data -and $setting.Data['ExportedFile']) {
                $targetFile = Join-Path $wifiDir $setting.Data['ExportedFile']
                if (-not (Test-Path $targetFile)) {
                    $targetFile = $null
                }
            }

            # Fallback: search by profile name in file name
            if (-not $targetFile) {
                $match = $xmlFiles | Where-Object {
                    $_.Name -match [regex]::Escape($setting.Name)
                } | Select-Object -First 1
                if ($match) {
                    $targetFile = $match.FullName
                }
            }

            if (-not $targetFile) {
                throw "No matching XML export file found for profile '$($setting.Name)'"
            }

            # Import the profile
            $importOutput = netsh wlan add profile filename="$targetFile" 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "netsh wlan add profile returned exit code $LASTEXITCODE : $importOutput"
            }

            $setting.ImportStatus = 'Success'
            Write-MigrationLog -Message "Imported WiFi profile: $($setting.Name)" -Level Debug
        }
        catch {
            $setting.ImportStatus = 'Failed'
            if (-not $setting.Data) { $setting.Data = @{} }
            $setting.Data['ImportError'] = $_.Exception.Message
            Write-MigrationLog -Message "Failed to import WiFi profile '$($setting.Name)': $($_.Exception.Message)" -Level Error
        }
    }

    $successCount = ($Settings | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "WiFi profile import complete: $successCount/$($Settings.Count) succeeded" -Level Success

    return $Settings
}
