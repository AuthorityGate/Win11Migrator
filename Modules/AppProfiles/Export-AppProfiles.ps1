<#
========================================================================================================
    Title:          Win11Migrator - Application Profile Exporter
    Filename:       Export-AppProfiles.ps1
    Description:    Detects and exports application profiles (settings, configs, registry) for migration.
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
    Detects and exports application profiles (settings, configs, registry) for migration.
.DESCRIPTION
    Loads AppProfileCatalog.json, matches entries against installed apps, checks which
    files/registry keys exist, and exports them to the migration package.
#>

function Get-DetectedAppProfiles {
    <#
    .SYNOPSIS
        Scans for application profiles that exist on this machine.
    .PARAMETER InstalledApps
        Array of installed app hashtables/objects with a .Name property.
    .OUTPUTS
        Array of hashtables describing detected profiles.
    #>
    [CmdletBinding()]
    param(
        [array]$InstalledApps = @()
    )

    $catalogPath = Join-Path $script:MigratorRoot "Config\AppProfileCatalog.json"
    if (-not (Test-Path $catalogPath)) {
        Write-MigrationLog -Message "AppProfileCatalog.json not found at $catalogPath" -Level Warning
        return @()
    }

    try {
        $catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json
    } catch {
        Write-MigrationLog -Message "Failed to load AppProfileCatalog.json: $($_.Exception.Message)" -Level Warning
        return @()
    }

    # Build list of installed app names for matching
    $appNames = @()
    foreach ($app in $InstalledApps) {
        if ($app.Name) { $appNames += $app.Name }
    }

    $detected = @()

    foreach ($entry in $catalog) {
        $matched = $false

        # Check if this profile matches installed apps or is always-scanned
        foreach ($pattern in $entry.DisplayMatch) {
            if ($pattern -eq '__always__') {
                $matched = $true
                break
            }
            foreach ($appName in $appNames) {
                if ($appName -like $pattern) {
                    $matched = $true
                    break
                }
            }
            if ($matched) { break }
        }

        if (-not $matched) { continue }

        # Check which files actually exist
        $existingFiles = @()
        foreach ($filePath in $entry.Files) {
            $expanded = [System.Environment]::ExpandEnvironmentVariables($filePath)
            if (Test-Path $expanded -ErrorAction SilentlyContinue) {
                $existingFiles += $expanded
            }
        }

        # Check which registry keys exist
        $existingRegistry = @()
        foreach ($regPath in $entry.Registry) {
            if (Test-Path $regPath -ErrorAction SilentlyContinue) {
                $existingRegistry += $regPath
            }
        }

        # Only include if at least one file or registry key exists
        if ($existingFiles.Count -gt 0 -or $existingRegistry.Count -gt 0) {
            $detected += @{
                Name             = $entry.Name
                Category         = $entry.Category
                Files            = $existingFiles
                Registry         = $existingRegistry
                FileCount        = $existingFiles.Count
                RegistryCount    = $existingRegistry.Count
                Selected         = $true
            }
            Write-MigrationLog -Message "App profile detected: $($entry.Name) ($($existingFiles.Count) files, $($existingRegistry.Count) registry)" -Level Info
        }
    }

    Write-MigrationLog -Message "App profile scan complete: $($detected.Count) profiles detected" -Level Success
    return $detected
}

function Export-AppProfiles {
    <#
    .SYNOPSIS
        Exports selected application profiles to the migration package.
    .PARAMETER Profiles
        Array of profile hashtables from Get-DetectedAppProfiles.
    .PARAMETER OutputPath
        Directory to export profiles to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Profiles,

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $exportedCount = 0

    foreach ($profile in $Profiles) {
        if (-not $profile.Selected) { continue }

        $profileDir = Join-Path $OutputPath ($profile.Name -replace '[\\/:*?"<>|]', '_')
        New-Item -Path $profileDir -ItemType Directory -Force | Out-Null

        # Export files via Robocopy (directories) or Copy-Item (single files)
        foreach ($filePath in $profile.Files) {
            try {
                if (Test-Path $filePath -PathType Container) {
                    $folderName = [System.IO.Path]::GetFileName($filePath.TrimEnd('\', '/'))
                    $destDir = Join-Path $profileDir $folderName
                    & robocopy $filePath $destDir /E /R:1 /W:1 /NJH /NJS /NFL /NDL /NP 2>&1 | Out-Null
                } else {
                    $destFile = Join-Path $profileDir ([System.IO.Path]::GetFileName($filePath))
                    Copy-Item -Path $filePath -Destination $destFile -Force -ErrorAction SilentlyContinue
                }
            } catch {
                Write-MigrationLog -Message "Failed to export file $filePath for $($profile.Name): $($_.Exception.Message)" -Level Warning
            }
        }

        # Export registry keys
        foreach ($regPath in $profile.Registry) {
            try {
                $regFileName = ($regPath -replace '[\\/:*?"<>|]', '_') + '.reg'
                $regFile = Join-Path $profileDir $regFileName
                # Convert PowerShell registry path to reg.exe format
                $regExePath = $regPath -replace '^HKCU:\\', 'HKCU\' -replace '^HKLM:\\', 'HKLM\'
                & reg export $regExePath $regFile /y 2>&1 | Out-Null
            } catch {
                Write-MigrationLog -Message "Failed to export registry $regPath for $($profile.Name): $($_.Exception.Message)" -Level Warning
            }
        }

        $exportedCount++
        Write-MigrationLog -Message "Exported app profile: $($profile.Name)" -Level Info
    }

    Write-MigrationLog -Message "App profile export complete: $exportedCount profiles exported" -Level Success
    return $exportedCount
}
