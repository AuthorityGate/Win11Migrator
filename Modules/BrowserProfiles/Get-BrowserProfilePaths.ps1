<#
========================================================================================================
    Title:          Win11Migrator - Browser Profile Path Discovery
    Filename:       Get-BrowserProfilePaths.ps1
    Description:    Discovers installed browser profile directories for Chrome, Edge, Firefox, and Brave.
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
    Detects installed browsers and enumerates their profile directories.
.DESCRIPTION
    Scans for Chrome, Edge, Firefox, and Brave. For Chromium-based browsers,
    enumerates Default and Profile N sub-folders. For Firefox, parses profiles.ini.
    Returns BrowserProfile[] with detection flags populated.
.OUTPUTS
    [BrowserProfile[]] Array of detected browser profiles.
#>

function Get-BrowserProfilePaths {
    [CmdletBinding()]
    param()

    Write-MigrationLog -Message "Scanning for installed browser profiles" -Level Info

    $profiles = [System.Collections.Generic.List[BrowserProfile]]::new()

    # Chromium-based browser definitions
    $chromiumBrowsers = @(
        @{ Name = 'Chrome'; UserDataPath = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data' }
        @{ Name = 'Edge';   UserDataPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data' }
        @{ Name = 'Brave';  UserDataPath = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data' }
    )

    foreach ($browser in $chromiumBrowsers) {
        $userDataPath = $browser.UserDataPath

        if (-not (Test-Path $userDataPath)) {
            Write-MigrationLog -Message "$($browser.Name) not detected at $userDataPath" -Level Debug
            continue
        }

        Write-MigrationLog -Message "$($browser.Name) detected at $userDataPath" -Level Info

        # Enumerate profile folders: 'Default' and 'Profile N'
        $profileDirs = Get-ChildItem -Path $userDataPath -Directory -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -eq 'Default' -or $_.Name -match '^Profile \d+$' }

        if (-not $profileDirs -or @($profileDirs).Count -eq 0) {
            Write-MigrationLog -Message "$($browser.Name) user data directory found but no profile folders detected" -Level Warning
            continue
        }

        foreach ($profileDir in $profileDirs) {
            $profilePath = $profileDir.FullName

            $bp = [BrowserProfile]::new()
            $bp.Browser       = $browser.Name
            $bp.ProfileName   = $profileDir.Name
            $bp.ProfilePath   = $profilePath
            $bp.Selected      = $true
            $bp.ExportStatus  = 'Pending'

            # Detect available data
            $bp.HasBookmarks  = Test-Path (Join-Path $profilePath 'Bookmarks')
            $bp.HasExtensions = Test-Path (Join-Path $profilePath 'Extensions')
            $bp.HasHistory    = Test-Path (Join-Path $profilePath 'History')
            $bp.HasPasswords  = Test-Path (Join-Path $profilePath 'Login Data')

            # Enumerate extension names if Extensions folder exists
            $bp.Extensions = @()
            if ($bp.HasExtensions) {
                $extDir = Join-Path $profilePath 'Extensions'
                $extFolders = Get-ChildItem -Path $extDir -Directory -ErrorAction SilentlyContinue
                foreach ($ext in $extFolders) {
                    # Each extension ID folder may contain version sub-folders with manifest.json
                    $versionDirs = Get-ChildItem -Path $ext.FullName -Directory -ErrorAction SilentlyContinue |
                                   Sort-Object Name -Descending |
                                   Select-Object -First 1
                    if ($versionDirs) {
                        $manifestFile = Join-Path $versionDirs.FullName 'manifest.json'
                        if (Test-Path $manifestFile) {
                            try {
                                $extManifest = Get-Content $manifestFile -Raw -ErrorAction Stop | ConvertFrom-Json
                                $extName = if ($extManifest.name -and $extManifest.name -notmatch '^__MSG_') {
                                    $extManifest.name
                                } else {
                                    $ext.Name
                                }
                                $bp.Extensions += "$extName ($($ext.Name))"
                            }
                            catch {
                                $bp.Extensions += $ext.Name
                            }
                        }
                    }
                }
            }

            Write-MigrationLog -Message "  $($browser.Name) profile '$($bp.ProfileName)': Bookmarks=$($bp.HasBookmarks), Extensions=$(@($bp.Extensions).Count), History=$($bp.HasHistory)" -Level Debug
            $profiles.Add($bp)
        }
    }

    # Firefox
    $firefoxProfilesPath = Join-Path $env:APPDATA 'Mozilla\Firefox'
    $firefoxProfilesIni  = Join-Path $firefoxProfilesPath 'profiles.ini'

    if (Test-Path $firefoxProfilesIni) {
        Write-MigrationLog -Message "Firefox detected, parsing profiles.ini" -Level Info

        try {
            $iniContent = Get-Content $firefoxProfilesIni -ErrorAction Stop
            $currentSection = $null
            $profileSections = @{}

            foreach ($line in $iniContent) {
                $line = $line.Trim()
                if ($line -match '^\[(.+)\]$') {
                    $currentSection = $Matches[1]
                    if ($currentSection -match '^Profile\d+$' -or $currentSection -match '^Install') {
                        if (-not $profileSections.ContainsKey($currentSection)) {
                            $profileSections[$currentSection] = @{}
                        }
                    }
                }
                elseif ($currentSection -and $profileSections.ContainsKey($currentSection) -and $line -match '^(.+?)=(.+)$') {
                    $profileSections[$currentSection][$Matches[1]] = $Matches[2]
                }
            }

            # Extract actual Profile sections
            foreach ($sectionName in $profileSections.Keys) {
                if ($sectionName -notmatch '^Profile\d+$') { continue }

                $section = $profileSections[$sectionName]
                $profileName = if ($section['Name']) { $section['Name'] } else { $sectionName }
                $isRelative  = $section['IsRelative'] -eq '1'
                $pathValue   = $section['Path']

                if (-not $pathValue) { continue }

                # Resolve the full path
                if ($isRelative) {
                    $profilePath = Join-Path $firefoxProfilesPath $pathValue
                }
                else {
                    $profilePath = $pathValue
                }

                # Normalize path separators (profiles.ini uses /)
                $profilePath = $profilePath -replace '/', '\'

                if (-not (Test-Path $profilePath)) {
                    Write-MigrationLog -Message "Firefox profile path does not exist: $profilePath" -Level Debug
                    continue
                }

                $bp = [BrowserProfile]::new()
                $bp.Browser       = 'Firefox'
                $bp.ProfileName   = $profileName
                $bp.ProfilePath   = $profilePath
                $bp.Selected      = $true
                $bp.ExportStatus  = 'Pending'

                # Detect available data
                $bp.HasBookmarks  = Test-Path (Join-Path $profilePath 'places.sqlite')
                $bp.HasHistory    = Test-Path (Join-Path $profilePath 'places.sqlite')
                $bp.HasPasswords  = (Test-Path (Join-Path $profilePath 'logins.json')) -or
                                    (Test-Path (Join-Path $profilePath 'key4.db'))

                # Extensions
                $extensionsJson = Join-Path $profilePath 'extensions.json'
                $bp.HasExtensions = Test-Path $extensionsJson
                $bp.Extensions = @()

                if ($bp.HasExtensions) {
                    try {
                        $extData = Get-Content $extensionsJson -Raw -ErrorAction Stop | ConvertFrom-Json
                        if ($extData.addons) {
                            foreach ($addon in $extData.addons) {
                                if ($addon.type -eq 'extension' -and $addon.name -and -not $addon.isSystem) {
                                    $bp.Extensions += "$($addon.name) ($($addon.id))"
                                }
                            }
                        }
                    }
                    catch {
                        Write-MigrationLog -Message "Failed to parse Firefox extensions.json: $($_.Exception.Message)" -Level Warning
                    }
                }

                Write-MigrationLog -Message "  Firefox profile '$profileName': Bookmarks=$($bp.HasBookmarks), Extensions=$(@($bp.Extensions).Count)" -Level Debug
                $profiles.Add($bp)
            }
        }
        catch {
            Write-MigrationLog -Message "Error reading Firefox profiles.ini: $($_.Exception.Message)" -Level Error
        }
    }
    else {
        Write-MigrationLog -Message "Firefox not detected (profiles.ini not found)" -Level Debug
    }

    Write-MigrationLog -Message "Browser scan complete. Found $($profiles.Count) profile(s) across installed browsers." -Level Success

    return $profiles.ToArray()
}
