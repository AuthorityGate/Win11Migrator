<#
========================================================================================================
    Title:          Win11Migrator - Chrome Profile Exporter
    Filename:       Export-ChromeProfile.ps1
    Description:    Exports Google Chrome bookmarks, extensions, settings, and history for migration.
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
    Exports a Chrome browser profile (bookmarks, preferences, extensions list, history).
.DESCRIPTION
    Copies the Bookmarks JSON, Preferences file, History SQLite database, and enumerates
    installed extensions (name + ID) from a Chrome profile folder. Passwords (Login Data)
    are explicitly excluded for security.
.PARAMETER Profile
    A BrowserProfile object for a Chrome profile.
.PARAMETER OutputDirectory
    Root of the migration package.
.OUTPUTS
    [BrowserProfile] Updated profile with ExportStatus set.
#>

function Export-ChromeProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [BrowserProfile]$Profile,

        [Parameter(Mandatory)]
        [string]$OutputDirectory
    )

    if ($Profile.Browser -ne 'Chrome') {
        Write-MigrationLog -Message "Export-ChromeProfile called with non-Chrome profile: $($Profile.Browser)" -Level Warning
        $Profile.ExportStatus = 'Skipped'
        return $Profile
    }

    $profileName = $Profile.ProfileName -replace '[^\w\-\.]', '_'
    $destPath = Join-Path $OutputDirectory "BrowserProfiles\Chrome\$profileName"
    $sourcePath = $Profile.ProfilePath

    Write-MigrationLog -Message "Exporting Chrome profile '$($Profile.ProfileName)' from $sourcePath" -Level Info

    try {
        if (-not (Test-Path $destPath)) {
            New-Item -Path $destPath -ItemType Directory -Force | Out-Null
        }

        $exportedAny = $false

        # Bookmarks
        $bookmarksFile = Join-Path $sourcePath 'Bookmarks'
        if (Test-Path $bookmarksFile) {
            Copy-Item -Path $bookmarksFile -Destination (Join-Path $destPath 'Bookmarks') -Force -ErrorAction Stop
            Write-MigrationLog -Message "  Chrome bookmarks exported" -Level Debug
            $exportedAny = $true
        }

        # Bookmarks backup
        $bookmarksBak = Join-Path $sourcePath 'Bookmarks.bak'
        if (Test-Path $bookmarksBak) {
            Copy-Item -Path $bookmarksBak -Destination (Join-Path $destPath 'Bookmarks.bak') -Force -ErrorAction Stop
        }

        # Preferences
        $prefsFile = Join-Path $sourcePath 'Preferences'
        if (Test-Path $prefsFile) {
            Copy-Item -Path $prefsFile -Destination (Join-Path $destPath 'Preferences') -Force -ErrorAction Stop
            Write-MigrationLog -Message "  Chrome preferences exported" -Level Debug
            $exportedAny = $true
        }

        # History (SQLite file - may be locked if Chrome is running)
        $historyFile = Join-Path $sourcePath 'History'
        if (Test-Path $historyFile) {
            try {
                Copy-Item -Path $historyFile -Destination (Join-Path $destPath 'History') -Force -ErrorAction Stop
                Write-MigrationLog -Message "  Chrome history exported" -Level Debug
                $exportedAny = $true
            }
            catch {
                Write-MigrationLog -Message "  Chrome history file is locked (browser may be running): $($_.Exception.Message)" -Level Warning
            }
        }

        # Extensions - enumerate and save a manifest (NOT the extension files themselves)
        $extensionsDir = Join-Path $sourcePath 'Extensions'
        if (Test-Path $extensionsDir) {
            $extensionList = [System.Collections.Generic.List[PSCustomObject]]::new()

            $extFolders = Get-ChildItem -Path $extensionsDir -Directory -ErrorAction SilentlyContinue
            foreach ($extFolder in $extFolders) {
                $extId = $extFolder.Name

                # Find the latest version sub-folder
                $versionDir = Get-ChildItem -Path $extFolder.FullName -Directory -ErrorAction SilentlyContinue |
                              Sort-Object Name -Descending |
                              Select-Object -First 1

                $extName    = $extId
                $extVersion = ''
                $extDesc    = ''

                if ($versionDir) {
                    $manifestJson = Join-Path $versionDir.FullName 'manifest.json'
                    if (Test-Path $manifestJson) {
                        try {
                            $manifest = Get-Content $manifestJson -Raw -ErrorAction Stop | ConvertFrom-Json
                            if ($manifest.name -and $manifest.name -notmatch '^__MSG_') {
                                $extName = $manifest.name
                            }
                            $extVersion = if ($manifest.version) { $manifest.version } else { '' }
                            $extDesc    = if ($manifest.description -and $manifest.description -notmatch '^__MSG_') { $manifest.description } else { '' }
                        }
                        catch {
                            Write-MigrationLog -Message "  Failed to parse extension manifest for $extId" -Level Debug
                        }
                    }
                }

                $extensionList.Add([PSCustomObject]@{
                    Id          = $extId
                    Name        = $extName
                    Version     = $extVersion
                    Description = $extDesc
                    WebStoreUrl = "https://chrome.google.com/webstore/detail/$extId"
                })
            }

            if ($extensionList.Count -gt 0) {
                $extensionList.ToArray() | ConvertTo-Json -Depth 5 |
                    Set-Content -Path (Join-Path $destPath 'extensions_list.json') -Encoding UTF8
                Write-MigrationLog -Message "  Chrome extensions list exported ($($extensionList.Count) extensions)" -Level Debug
                $exportedAny = $true
            }
        }

        # Explicitly do NOT export Login Data / passwords
        Write-MigrationLog -Message "  Chrome Login Data (passwords) intentionally excluded for security" -Level Debug

        if ($exportedAny) {
            $Profile.ExportStatus = 'Success'
            Write-MigrationLog -Message "Chrome profile '$($Profile.ProfileName)' export complete" -Level Success
        }
        else {
            $Profile.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Chrome profile '$($Profile.ProfileName)' had no data to export" -Level Warning
        }
    }
    catch {
        $Profile.ExportStatus = 'Failed'
        Write-MigrationLog -Message "Failed to export Chrome profile '$($Profile.ProfileName)': $($_.Exception.Message)" -Level Error
    }

    return $Profile
}
