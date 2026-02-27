<#
========================================================================================================
    Title:          Win11Migrator - Brave Profile Exporter
    Filename:       Export-BraveProfile.ps1
    Description:    Exports Brave browser bookmarks, extensions, settings, and history for migration.
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
    Exports a Brave browser profile (bookmarks, preferences, extensions list, history).
.DESCRIPTION
    Brave is Chromium-based and uses the same profile structure as Chrome.
    Copies the Bookmarks JSON, Preferences, History, and enumerates installed extensions.
    Passwords are explicitly excluded for security.
.PARAMETER Profile
    A BrowserProfile object for a Brave profile.
.PARAMETER OutputDirectory
    Root of the migration package.
.OUTPUTS
    [BrowserProfile] Updated profile with ExportStatus set.
#>

function Export-BraveProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [BrowserProfile]$Profile,

        [Parameter(Mandatory)]
        [string]$OutputDirectory
    )

    if ($Profile.Browser -ne 'Brave') {
        Write-MigrationLog -Message "Export-BraveProfile called with non-Brave profile: $($Profile.Browser)" -Level Warning
        $Profile.ExportStatus = 'Skipped'
        return $Profile
    }

    $profileName = $Profile.ProfileName -replace '[^\w\-\.]', '_'
    $destPath = Join-Path $OutputDirectory "BrowserProfiles\Brave\$profileName"
    $sourcePath = $Profile.ProfilePath

    Write-MigrationLog -Message "Exporting Brave profile '$($Profile.ProfileName)' from $sourcePath" -Level Info

    try {
        if (-not (Test-Path $destPath)) {
            New-Item -Path $destPath -ItemType Directory -Force | Out-Null
        }

        $exportedAny = $false

        # Bookmarks
        $bookmarksFile = Join-Path $sourcePath 'Bookmarks'
        if (Test-Path $bookmarksFile) {
            Copy-Item -Path $bookmarksFile -Destination (Join-Path $destPath 'Bookmarks') -Force -ErrorAction Stop
            Write-MigrationLog -Message "  Brave bookmarks exported" -Level Debug
            $exportedAny = $true
        }

        $bookmarksBak = Join-Path $sourcePath 'Bookmarks.bak'
        if (Test-Path $bookmarksBak) {
            Copy-Item -Path $bookmarksBak -Destination (Join-Path $destPath 'Bookmarks.bak') -Force -ErrorAction Stop
        }

        # Preferences
        $prefsFile = Join-Path $sourcePath 'Preferences'
        if (Test-Path $prefsFile) {
            Copy-Item -Path $prefsFile -Destination (Join-Path $destPath 'Preferences') -Force -ErrorAction Stop
            Write-MigrationLog -Message "  Brave preferences exported" -Level Debug
            $exportedAny = $true
        }

        # History
        $historyFile = Join-Path $sourcePath 'History'
        if (Test-Path $historyFile) {
            try {
                Copy-Item -Path $historyFile -Destination (Join-Path $destPath 'History') -Force -ErrorAction Stop
                Write-MigrationLog -Message "  Brave history exported" -Level Debug
                $exportedAny = $true
            }
            catch {
                Write-MigrationLog -Message "  Brave history file is locked (browser may be running): $($_.Exception.Message)" -Level Warning
            }
        }

        # Extensions list
        $extensionsDir = Join-Path $sourcePath 'Extensions'
        if (Test-Path $extensionsDir) {
            $extensionList = [System.Collections.Generic.List[PSCustomObject]]::new()

            $extFolders = Get-ChildItem -Path $extensionsDir -Directory -ErrorAction SilentlyContinue
            foreach ($extFolder in $extFolders) {
                $extId = $extFolder.Name

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
                            Write-MigrationLog -Message "  Failed to parse Brave extension manifest for $extId" -Level Debug
                        }
                    }
                }

                $extensionList.Add([PSCustomObject]@{
                    Id              = $extId
                    Name            = $extName
                    Version         = $extVersion
                    Description     = $extDesc
                    ChromeStoreUrl  = "https://chrome.google.com/webstore/detail/$extId"
                })
            }

            if ($extensionList.Count -gt 0) {
                $extensionList.ToArray() | ConvertTo-Json -Depth 5 |
                    Set-Content -Path (Join-Path $destPath 'extensions_list.json') -Encoding UTF8
                Write-MigrationLog -Message "  Brave extensions list exported ($($extensionList.Count) extensions)" -Level Debug
                $exportedAny = $true
            }
        }

        # Explicitly do NOT export Login Data / passwords
        Write-MigrationLog -Message "  Brave Login Data (passwords) intentionally excluded for security" -Level Debug

        if ($exportedAny) {
            $Profile.ExportStatus = 'Success'
            Write-MigrationLog -Message "Brave profile '$($Profile.ProfileName)' export complete" -Level Success
        }
        else {
            $Profile.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Brave profile '$($Profile.ProfileName)' had no data to export" -Level Warning
        }
    }
    catch {
        $Profile.ExportStatus = 'Failed'
        Write-MigrationLog -Message "Failed to export Brave profile '$($Profile.ProfileName)': $($_.Exception.Message)" -Level Error
    }

    return $Profile
}
