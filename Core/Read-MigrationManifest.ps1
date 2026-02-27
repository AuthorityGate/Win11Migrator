<#
========================================================================================================
    Title:          Win11Migrator - Migration Manifest Reader
    Filename:       Read-MigrationManifest.ps1
    Description:    Reads and deserializes a migration manifest JSON file from a migration package.
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
    Deserialize and validate a migration manifest.json file.
#>

function Read-MigrationManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath
    )

    if (-not (Test-Path $ManifestPath)) {
        throw "Manifest not found: $ManifestPath"
    }

    $json = Get-Content $ManifestPath -Raw -Encoding UTF8
    $raw = $json | ConvertFrom-Json

    # Validate required fields
    $requiredFields = @('Version', 'ExportDate', 'SourceComputerName')
    foreach ($field in $requiredFields) {
        if (-not $raw.$field) {
            throw "Manifest is missing required field: $field"
        }
    }

    # Reconstruct typed objects
    $manifest = [MigrationManifest]::new()
    $manifest.Version = $raw.Version
    $manifest.ExportDate = $raw.ExportDate
    $manifest.SourceComputerName = $raw.SourceComputerName
    $manifest.SourceOSVersion = $raw.SourceOSVersion
    $manifest.SourceUserName = $raw.SourceUserName

    # Reconstruct apps
    if ($raw.Apps) {
        $manifest.Apps = $raw.Apps | ForEach-Object {
            $app = [MigrationApp]::new()
            $_.PSObject.Properties | ForEach-Object {
                if ($app.PSObject.Properties[$_.Name]) {
                    $app.$($_.Name) = $_.Value
                }
            }
            $app
        }
    }

    # Reconstruct user data items
    if ($raw.UserData) {
        $manifest.UserData = $raw.UserData | ForEach-Object {
            $item = [UserDataItem]::new()
            $_.PSObject.Properties | ForEach-Object {
                if ($item.PSObject.Properties[$_.Name]) {
                    $item.$($_.Name) = $_.Value
                }
            }
            $item
        }
    }

    # Reconstruct browser profiles
    if ($raw.BrowserProfiles) {
        $manifest.BrowserProfiles = $raw.BrowserProfiles | ForEach-Object {
            $profile = [BrowserProfile]::new()
            $_.PSObject.Properties | ForEach-Object {
                if ($profile.PSObject.Properties[$_.Name]) {
                    $profile.$($_.Name) = $_.Value
                }
            }
            $profile
        }
    }

    # Reconstruct system settings
    if ($raw.SystemSettings) {
        $manifest.SystemSettings = $raw.SystemSettings | ForEach-Object {
            $setting = [SystemSetting]::new()
            $_.PSObject.Properties | ForEach-Object {
                if ($setting.PSObject.Properties[$_.Name]) {
                    $setting.$($_.Name) = $_.Value
                }
            }
            $setting
        }
    }

    # Reconstruct app profiles (stored as hashtable[], deserialized as PSCustomObject[])
    if ($raw.AppProfiles) {
        $manifest.AppProfiles = @($raw.AppProfiles | ForEach-Object {
            $ht = @{}
            $_.PSObject.Properties | ForEach-Object {
                $val = $_.Value
                # Convert nested arrays back from Object[] to proper types
                if ($val -is [System.Object[]]) {
                    $val = @($val)
                }
                $ht[$_.Name] = $val
            }
            $ht
        })
    }

    if ($raw.Metadata) {
        $manifest.Metadata = @{}
        $raw.Metadata.PSObject.Properties | ForEach-Object {
            $manifest.Metadata[$_.Name] = $_.Value
        }
    }

    Write-MigrationLog -Message "Manifest loaded: $($manifest.Apps.Count) apps, $($manifest.UserData.Count) data items, $($manifest.BrowserProfiles.Count) browser profiles, $($manifest.SystemSettings.Count) system settings, $($manifest.AppProfiles.Count) app profiles" -Level Info

    return $manifest
}
