<#
========================================================================================================
    Title:          Win11Migrator - Edge Profile Importer
    Filename:       Import-EdgeProfile.ps1
    Description:    Imports Microsoft Edge bookmarks, extensions, settings, and history from a migration package.
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
    Restores a Microsoft Edge browser profile from a migration package.
.DESCRIPTION
    Restores bookmarks and preferences to the Edge profile directory. For extensions,
    generates an HTML page with links to the Edge Add-ons store for easy reinstallation.
    Waits for Edge to not be running before restoring files.
.PARAMETER Profile
    A BrowserProfile object for an Edge profile.
.PARAMETER PackagePath
    Root of the migration package.
.PARAMETER WaitTimeoutSeconds
    Maximum seconds to wait for Edge to close. Defaults to 60.
.OUTPUTS
    [BrowserProfile] Updated profile with ExportStatus reflecting import result.
#>

function Import-EdgeProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [BrowserProfile]$Profile,

        [Parameter(Mandatory)]
        [string]$PackagePath,

        [int]$WaitTimeoutSeconds = 60
    )

    if ($Profile.Browser -ne 'Edge') {
        Write-MigrationLog -Message "Import-EdgeProfile called with non-Edge profile: $($Profile.Browser)" -Level Warning
        $Profile.ExportStatus = 'Skipped'
        return $Profile
    }

    $profileName = $Profile.ProfileName -replace '[^\w\-\.]', '_'
    # PackagePath is the profile-specific directory (e.g. .../BrowserProfiles/Edge_Default)
    $sourcePath = $PackagePath
    $targetProfilePath = $Profile.ProfilePath

    Write-MigrationLog -Message "Importing Edge profile '$($Profile.ProfileName)' to $targetProfilePath" -Level Info

    if (-not (Test-Path $sourcePath)) {
        $Profile.ExportStatus = 'Failed'
        Write-MigrationLog -Message "Edge profile package not found: $sourcePath" -Level Warning
        return $Profile
    }

    # If target path does not exist, construct it
    if (-not $targetProfilePath -or -not (Test-Path (Split-Path $targetProfilePath -Parent) -ErrorAction SilentlyContinue)) {
        $edgeUserData = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
        $targetProfilePath = Join-Path $edgeUserData $Profile.ProfileName
    }

    try {
        # Wait for Edge to close
        $waited = 0
        while ((Get-Process -Name 'msedge' -ErrorAction SilentlyContinue) -and $waited -lt $WaitTimeoutSeconds) {
            if ($waited -eq 0) {
                Write-MigrationLog -Message "Edge is running. Waiting for it to close before restoring profile..." -Level Warning
            }
            Start-Sleep -Seconds 5
            $waited += 5
        }

        if (Get-Process -Name 'msedge' -ErrorAction SilentlyContinue) {
            Write-MigrationLog -Message "Edge is still running after $WaitTimeoutSeconds seconds. Attempting import anyway." -Level Warning
        }

        if (-not (Test-Path $targetProfilePath)) {
            New-Item -Path $targetProfilePath -ItemType Directory -Force | Out-Null
        }

        $importedAny = $false

        # Bookmarks
        $bookmarksFile = Join-Path $sourcePath 'Bookmarks'
        if (Test-Path $bookmarksFile) {
            $existingBookmarks = Join-Path $targetProfilePath 'Bookmarks'
            if (Test-Path $existingBookmarks) {
                $backupName = "Bookmarks.pre_migration_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                Copy-Item -Path $existingBookmarks -Destination (Join-Path $targetProfilePath $backupName) -Force
                Write-MigrationLog -Message "  Existing Edge bookmarks backed up as $backupName" -Level Debug
            }

            Copy-Item -Path $bookmarksFile -Destination $existingBookmarks -Force -ErrorAction Stop
            Write-MigrationLog -Message "  Edge bookmarks restored" -Level Debug
            $importedAny = $true
        }

        $bookmarksBak = Join-Path $sourcePath 'Bookmarks.bak'
        if (Test-Path $bookmarksBak) {
            Copy-Item -Path $bookmarksBak -Destination (Join-Path $targetProfilePath 'Bookmarks.bak') -Force -ErrorAction Stop
        }

        # Preferences
        $prefsFile = Join-Path $sourcePath 'Preferences'
        if (Test-Path $prefsFile) {
            $existingPrefs = Join-Path $targetProfilePath 'Preferences'
            if (Test-Path $existingPrefs) {
                $backupName = "Preferences.pre_migration_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                Copy-Item -Path $existingPrefs -Destination (Join-Path $targetProfilePath $backupName) -Force
            }

            Copy-Item -Path $prefsFile -Destination $existingPrefs -Force -ErrorAction Stop
            Write-MigrationLog -Message "  Edge preferences restored" -Level Debug
            $importedAny = $true
        }

        # History
        $historyFile = Join-Path $sourcePath 'History'
        if (Test-Path $historyFile) {
            try {
                Copy-Item -Path $historyFile -Destination (Join-Path $targetProfilePath 'History') -Force -ErrorAction Stop
                Write-MigrationLog -Message "  Edge history restored" -Level Debug
                $importedAny = $true
            }
            catch {
                Write-MigrationLog -Message "  Edge history restore failed (file may be locked): $($_.Exception.Message)" -Level Warning
            }
        }

        # Extensions - generate an HTML file with install links
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
    <title>Edge Extensions - Reinstall</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 40px; background: #f5f5f5; }
        h1 { color: #0078d4; }
        .info { color: #666; margin-bottom: 20px; }
        .ext-list { list-style: none; padding: 0; }
        .ext-list li { background: white; margin: 8px 0; padding: 16px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        .ext-list li a { color: #0078d4; text-decoration: none; font-weight: 600; font-size: 16px; }
        .ext-list li a:hover { text-decoration: underline; }
        .ext-meta { color: #888; font-size: 13px; margin-top: 4px; }
    </style>
</head>
<body>
    <h1>Edge Extensions from Previous Installation</h1>
    <p class="info">Click each link below to reinstall the extension from the Microsoft Edge Add-ons store.</p>
    <ul class="ext-list">
"@

                foreach ($ext in $extensionList) {
                    $name = if ($ext.Name) { [System.Web.HttpUtility]::HtmlEncode($ext.Name) } else { $ext.Id }
                    $desc = if ($ext.Description) { [System.Web.HttpUtility]::HtmlEncode($ext.Description) } else { '' }
                    $url  = if ($ext.EdgeAddOnUrl) { $ext.EdgeAddOnUrl } else { "https://microsoftedge.microsoft.com/addons/detail/$($ext.Id)" }

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
                Write-MigrationLog -Message "  Edge extensions reinstall page created: $htmlPath ($(@($extensionList).Count) extensions)" -Level Debug
                $importedAny = $true
            }
            catch {
                Write-MigrationLog -Message "  Failed to generate Edge extensions HTML: $($_.Exception.Message)" -Level Warning
            }
        }

        if ($importedAny) {
            $Profile.ExportStatus = 'Success'
            Write-MigrationLog -Message "Edge profile '$($Profile.ProfileName)' import complete" -Level Success
        }
        else {
            $Profile.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Edge profile '$($Profile.ProfileName)' had no data to import" -Level Warning
        }
    }
    catch {
        $Profile.ExportStatus = 'Failed'
        Write-MigrationLog -Message "Failed to import Edge profile '$($Profile.ProfileName)': $($_.Exception.Message)" -Level Error
    }

    return $Profile
}
