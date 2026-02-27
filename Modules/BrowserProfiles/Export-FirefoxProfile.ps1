<#
========================================================================================================
    Title:          Win11Migrator - Firefox Profile Exporter
    Filename:       Export-FirefoxProfile.ps1
    Description:    Exports Mozilla Firefox bookmarks, extensions, settings, and history for migration.
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
    Exports a Firefox browser profile (bookmarks/history, extensions list, preferences).
.DESCRIPTION
    Copies places.sqlite (bookmarks + history), extensions.json, and prefs.js from
    a Firefox profile folder. Passwords (logins.json, key4.db) are excluded for security.
.PARAMETER Profile
    A BrowserProfile object for a Firefox profile.
.PARAMETER OutputDirectory
    Root of the migration package.
.OUTPUTS
    [BrowserProfile] Updated profile with ExportStatus set.
#>

function Export-FirefoxProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [BrowserProfile]$Profile,

        [Parameter(Mandatory)]
        [string]$OutputDirectory
    )

    if ($Profile.Browser -ne 'Firefox') {
        Write-MigrationLog -Message "Export-FirefoxProfile called with non-Firefox profile: $($Profile.Browser)" -Level Warning
        $Profile.ExportStatus = 'Skipped'
        return $Profile
    }

    $profileName = $Profile.ProfileName -replace '[^\w\-\.]', '_'
    $destPath = Join-Path $OutputDirectory "BrowserProfiles\Firefox\$profileName"
    $sourcePath = $Profile.ProfilePath

    Write-MigrationLog -Message "Exporting Firefox profile '$($Profile.ProfileName)' from $sourcePath" -Level Info

    try {
        if (-not (Test-Path $destPath)) {
            New-Item -Path $destPath -ItemType Directory -Force | Out-Null
        }

        $exportedAny = $false

        # places.sqlite - contains bookmarks and history
        $placesFile = Join-Path $sourcePath 'places.sqlite'
        if (Test-Path $placesFile) {
            try {
                Copy-Item -Path $placesFile -Destination (Join-Path $destPath 'places.sqlite') -Force -ErrorAction Stop
                Write-MigrationLog -Message "  Firefox places.sqlite exported (bookmarks + history)" -Level Debug
                $exportedAny = $true
            }
            catch {
                Write-MigrationLog -Message "  Firefox places.sqlite is locked (browser may be running): $($_.Exception.Message)" -Level Warning
            }
        }

        # favicons.sqlite - bookmark favicons, useful companion to places.sqlite
        $faviconsFile = Join-Path $sourcePath 'favicons.sqlite'
        if (Test-Path $faviconsFile) {
            try {
                Copy-Item -Path $faviconsFile -Destination (Join-Path $destPath 'favicons.sqlite') -Force -ErrorAction Stop
                Write-MigrationLog -Message "  Firefox favicons.sqlite exported" -Level Debug
            }
            catch {
                Write-MigrationLog -Message "  Firefox favicons.sqlite copy failed (non-critical): $($_.Exception.Message)" -Level Debug
            }
        }

        # prefs.js - user preferences
        $prefsFile = Join-Path $sourcePath 'prefs.js'
        if (Test-Path $prefsFile) {
            Copy-Item -Path $prefsFile -Destination (Join-Path $destPath 'prefs.js') -Force -ErrorAction Stop
            Write-MigrationLog -Message "  Firefox prefs.js exported" -Level Debug
            $exportedAny = $true
        }

        # user.js - user overrides (may not exist)
        $userJsFile = Join-Path $sourcePath 'user.js'
        if (Test-Path $userJsFile) {
            Copy-Item -Path $userJsFile -Destination (Join-Path $destPath 'user.js') -Force -ErrorAction Stop
            Write-MigrationLog -Message "  Firefox user.js exported" -Level Debug
        }

        # search.json.mozlz4 - custom search engines
        $searchFile = Join-Path $sourcePath 'search.json.mozlz4'
        if (Test-Path $searchFile) {
            Copy-Item -Path $searchFile -Destination (Join-Path $destPath 'search.json.mozlz4') -Force -ErrorAction Stop
            Write-MigrationLog -Message "  Firefox search engines exported" -Level Debug
        }

        # Extensions - export the list from extensions.json
        $extensionsJson = Join-Path $sourcePath 'extensions.json'
        if (Test-Path $extensionsJson) {
            # Copy the raw file
            Copy-Item -Path $extensionsJson -Destination (Join-Path $destPath 'extensions.json') -Force -ErrorAction Stop

            # Also generate a human-readable list
            try {
                $extData = Get-Content $extensionsJson -Raw -ErrorAction Stop | ConvertFrom-Json
                $extensionList = [System.Collections.Generic.List[PSCustomObject]]::new()

                if ($extData.addons) {
                    foreach ($addon in $extData.addons) {
                        if ($addon.type -eq 'extension' -and -not $addon.isSystem) {
                            $extensionList.Add([PSCustomObject]@{
                                Id          = $addon.id
                                Name        = $addon.name
                                Version     = $addon.version
                                Description = if ($addon.description) { $addon.description } else { '' }
                                AmoUrl      = if ($addon.sourceURI) { $addon.sourceURI } else { "https://addons.mozilla.org/addon/$($addon.id)" }
                            })
                        }
                    }
                }

                if ($extensionList.Count -gt 0) {
                    $extensionList.ToArray() | ConvertTo-Json -Depth 5 |
                        Set-Content -Path (Join-Path $destPath 'extensions_list.json') -Encoding UTF8
                    Write-MigrationLog -Message "  Firefox extensions list exported ($($extensionList.Count) extensions)" -Level Debug
                }
            }
            catch {
                Write-MigrationLog -Message "  Failed to parse Firefox extensions.json: $($_.Exception.Message)" -Level Warning
            }
            $exportedAny = $true
        }

        # Explicitly do NOT export logins.json or key4.db (passwords)
        Write-MigrationLog -Message "  Firefox password files (logins.json, key4.db) intentionally excluded for security" -Level Debug

        if ($exportedAny) {
            $Profile.ExportStatus = 'Success'
            Write-MigrationLog -Message "Firefox profile '$($Profile.ProfileName)' export complete" -Level Success
        }
        else {
            $Profile.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Firefox profile '$($Profile.ProfileName)' had no data to export" -Level Warning
        }
    }
    catch {
        $Profile.ExportStatus = 'Failed'
        Write-MigrationLog -Message "Failed to export Firefox profile '$($Profile.ProfileName)': $($_.Exception.Message)" -Level Error
    }

    return $Profile
}
