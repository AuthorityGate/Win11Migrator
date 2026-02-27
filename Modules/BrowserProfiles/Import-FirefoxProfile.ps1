<#
========================================================================================================
    Title:          Win11Migrator - Firefox Profile Importer
    Filename:       Import-FirefoxProfile.ps1
    Description:    Imports Mozilla Firefox bookmarks, extensions, settings, and history from a migration package.
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
    Restores a Firefox browser profile from a migration package.
.DESCRIPTION
    Restores places.sqlite (bookmarks + history), prefs.js, search engines, and
    extensions metadata to a Firefox profile folder. Handles Firefox's profile
    directory structure including profiles.ini-based path resolution.
    Waits for Firefox to not be running before restoring files.
.PARAMETER Profile
    A BrowserProfile object for a Firefox profile.
.PARAMETER PackagePath
    Root of the migration package.
.PARAMETER WaitTimeoutSeconds
    Maximum seconds to wait for Firefox to close. Defaults to 60.
.OUTPUTS
    [BrowserProfile] Updated profile with ExportStatus reflecting import result.
#>

function Import-FirefoxProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [BrowserProfile]$Profile,

        [Parameter(Mandatory)]
        [string]$PackagePath,

        [int]$WaitTimeoutSeconds = 60
    )

    if ($Profile.Browser -ne 'Firefox') {
        Write-MigrationLog -Message "Import-FirefoxProfile called with non-Firefox profile: $($Profile.Browser)" -Level Warning
        $Profile.ExportStatus = 'Skipped'
        return $Profile
    }

    $profileName = $Profile.ProfileName -replace '[^\w\-\.]', '_'
    # PackagePath is the profile-specific directory (e.g. .../BrowserProfiles/Firefox_profilename)
    $sourcePath = $PackagePath
    $targetProfilePath = $Profile.ProfilePath

    Write-MigrationLog -Message "Importing Firefox profile '$($Profile.ProfileName)' to $targetProfilePath" -Level Info

    if (-not (Test-Path $sourcePath)) {
        $Profile.ExportStatus = 'Failed'
        Write-MigrationLog -Message "Firefox profile package not found: $sourcePath" -Level Warning
        return $Profile
    }

    # If the target profile path does not exist, try to find the correct Firefox profile
    if (-not $targetProfilePath -or -not (Test-Path $targetProfilePath -ErrorAction SilentlyContinue)) {
        Write-MigrationLog -Message "Target Firefox profile path not found. Attempting to locate a matching profile." -Level Warning

        $firefoxProfilesPath = Join-Path $env:APPDATA 'Mozilla\Firefox'
        $profilesIni = Join-Path $firefoxProfilesPath 'profiles.ini'

        if (Test-Path $profilesIni) {
            # Try to find the default profile or a profile with a matching name
            $detectedProfiles = Get-BrowserProfilePaths | Where-Object { $_.Browser -eq 'Firefox' }
            if ($detectedProfiles) {
                # Prefer a profile with the same name; otherwise use the first one
                $match = $detectedProfiles | Where-Object { $_.ProfileName -eq $Profile.ProfileName } | Select-Object -First 1
                if (-not $match) {
                    $match = $detectedProfiles | Select-Object -First 1
                }
                $targetProfilePath = $match.ProfilePath
                Write-MigrationLog -Message "Resolved Firefox target profile: $targetProfilePath" -Level Info
            }
        }

        if (-not $targetProfilePath -or -not (Test-Path $targetProfilePath -ErrorAction SilentlyContinue)) {
            # Create a new profile directory as a last resort
            $firefoxProfilesDir = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
            $targetProfilePath = Join-Path $firefoxProfilesDir "migrated.$profileName"
            Write-MigrationLog -Message "Creating new Firefox profile directory: $targetProfilePath" -Level Warning
        }
    }

    try {
        # Wait for Firefox to close
        $waited = 0
        while ((Get-Process -Name 'firefox' -ErrorAction SilentlyContinue) -and $waited -lt $WaitTimeoutSeconds) {
            if ($waited -eq 0) {
                Write-MigrationLog -Message "Firefox is running. Waiting for it to close before restoring profile..." -Level Warning
            }
            Start-Sleep -Seconds 5
            $waited += 5
        }

        if (Get-Process -Name 'firefox' -ErrorAction SilentlyContinue) {
            Write-MigrationLog -Message "Firefox is still running after $WaitTimeoutSeconds seconds. Attempting import anyway." -Level Warning
        }

        if (-not (Test-Path $targetProfilePath)) {
            New-Item -Path $targetProfilePath -ItemType Directory -Force | Out-Null
        }

        $importedAny = $false

        # places.sqlite - bookmarks and history
        $placesFile = Join-Path $sourcePath 'places.sqlite'
        if (Test-Path $placesFile) {
            $existingPlaces = Join-Path $targetProfilePath 'places.sqlite'
            if (Test-Path $existingPlaces) {
                $backupName = "places.sqlite.pre_migration_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                try {
                    Copy-Item -Path $existingPlaces -Destination (Join-Path $targetProfilePath $backupName) -Force
                    Write-MigrationLog -Message "  Existing Firefox places.sqlite backed up as $backupName" -Level Debug
                }
                catch {
                    Write-MigrationLog -Message "  Could not back up existing places.sqlite: $($_.Exception.Message)" -Level Warning
                }
            }

            try {
                Copy-Item -Path $placesFile -Destination $existingPlaces -Force -ErrorAction Stop
                Write-MigrationLog -Message "  Firefox places.sqlite restored (bookmarks + history)" -Level Debug
                $importedAny = $true
            }
            catch {
                Write-MigrationLog -Message "  Firefox places.sqlite restore failed (file may be locked): $($_.Exception.Message)" -Level Warning
            }
        }

        # favicons.sqlite
        $faviconsFile = Join-Path $sourcePath 'favicons.sqlite'
        if (Test-Path $faviconsFile) {
            try {
                Copy-Item -Path $faviconsFile -Destination (Join-Path $targetProfilePath 'favicons.sqlite') -Force -ErrorAction Stop
                Write-MigrationLog -Message "  Firefox favicons.sqlite restored" -Level Debug
            }
            catch {
                Write-MigrationLog -Message "  Firefox favicons.sqlite restore failed (non-critical): $($_.Exception.Message)" -Level Debug
            }
        }

        # prefs.js - user preferences
        $prefsFile = Join-Path $sourcePath 'prefs.js'
        if (Test-Path $prefsFile) {
            $existingPrefs = Join-Path $targetProfilePath 'prefs.js'
            if (Test-Path $existingPrefs) {
                $backupName = "prefs.js.pre_migration_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                Copy-Item -Path $existingPrefs -Destination (Join-Path $targetProfilePath $backupName) -Force
                Write-MigrationLog -Message "  Existing Firefox prefs.js backed up" -Level Debug
            }

            Copy-Item -Path $prefsFile -Destination $existingPrefs -Force -ErrorAction Stop
            Write-MigrationLog -Message "  Firefox prefs.js restored" -Level Debug
            $importedAny = $true
        }

        # user.js
        $userJsFile = Join-Path $sourcePath 'user.js'
        if (Test-Path $userJsFile) {
            Copy-Item -Path $userJsFile -Destination (Join-Path $targetProfilePath 'user.js') -Force -ErrorAction Stop
            Write-MigrationLog -Message "  Firefox user.js restored" -Level Debug
        }

        # search.json.mozlz4 - search engines
        $searchFile = Join-Path $sourcePath 'search.json.mozlz4'
        if (Test-Path $searchFile) {
            Copy-Item -Path $searchFile -Destination (Join-Path $targetProfilePath 'search.json.mozlz4') -Force -ErrorAction Stop
            Write-MigrationLog -Message "  Firefox search engines restored" -Level Debug
        }

        # extensions.json
        $extensionsJson = Join-Path $sourcePath 'extensions.json'
        if (Test-Path $extensionsJson) {
            Copy-Item -Path $extensionsJson -Destination (Join-Path $targetProfilePath 'extensions.json') -Force -ErrorAction Stop
            Write-MigrationLog -Message "  Firefox extensions.json restored" -Level Debug
            $importedAny = $true
        }

        # Generate extensions reinstall guide from the readable list
        $extensionsListFile = Join-Path $sourcePath 'extensions_list.json'
        if (Test-Path $extensionsListFile) {
            try {
                $extensionList = Get-Content $extensionsListFile -Raw -ErrorAction Stop | ConvertFrom-Json
                $htmlPath = Join-Path $targetProfilePath 'reinstall_extensions.html'

                $htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Firefox Extensions - Reinstall</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 40px; background: #f5f5f5; }
        h1 { color: #ff7139; }
        .info { color: #666; margin-bottom: 20px; }
        .ext-list { list-style: none; padding: 0; }
        .ext-list li { background: white; margin: 8px 0; padding: 16px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        .ext-list li a { color: #0060df; text-decoration: none; font-weight: 600; font-size: 16px; }
        .ext-list li a:hover { text-decoration: underline; }
        .ext-meta { color: #888; font-size: 13px; margin-top: 4px; }
    </style>
</head>
<body>
    <h1>Firefox Extensions from Previous Installation</h1>
    <p class="info">Click each link below to reinstall the extension from Firefox Add-ons.</p>
    <ul class="ext-list">
"@

                foreach ($ext in $extensionList) {
                    $name = if ($ext.Name) { [System.Web.HttpUtility]::HtmlEncode($ext.Name) } else { $ext.Id }
                    $desc = if ($ext.Description) { [System.Web.HttpUtility]::HtmlEncode($ext.Description) } else { '' }
                    $url  = if ($ext.AmoUrl) { $ext.AmoUrl } else { "https://addons.mozilla.org/addon/$($ext.Id)" }

                    $htmlContent += @"

        <li>
            <a href="$url" target="_blank">$name</a>
            <div class="ext-meta">ID: $($ext.Id) | Version: $($ext.Version)</div>
            $(if ($desc) { "<div class='ext-meta'>$desc</div>" })
        </li>
"@
                }

                $htmlContent += @"

    </ul>
    <p class="info">Generated by Win11Migrator on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
</body>
</html>
"@

                Set-Content -Path $htmlPath -Value $htmlContent -Encoding UTF8
                Write-MigrationLog -Message "  Firefox extensions reinstall page created: $htmlPath" -Level Debug
            }
            catch {
                Write-MigrationLog -Message "  Failed to generate Firefox extensions HTML: $($_.Exception.Message)" -Level Warning
            }
        }

        if ($importedAny) {
            $Profile.ExportStatus = 'Success'
            Write-MigrationLog -Message "Firefox profile '$($Profile.ProfileName)' import complete" -Level Success
        }
        else {
            $Profile.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Firefox profile '$($Profile.ProfileName)' had no data to import" -Level Warning
        }
    }
    catch {
        $Profile.ExportStatus = 'Failed'
        Write-MigrationLog -Message "Failed to import Firefox profile '$($Profile.ProfileName)': $($_.Exception.Message)" -Level Error
    }

    return $Profile
}
