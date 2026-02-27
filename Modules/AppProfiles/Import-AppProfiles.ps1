<#
========================================================================================================
    Title:          Win11Migrator - Application Profile Importer
    Filename:       Import-AppProfiles.ps1
    Description:    Imports application profiles (settings, configs, registry) from a migration package.
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
    Imports application profiles (settings, configs, registry) from a migration package.
#>

function Import-AppProfiles {
    <#
    .SYNOPSIS
        Restores application profiles from the migration package to the target machine.
    .PARAMETER SourcePath
        Directory containing exported app profiles.
    .PARAMETER Profiles
        Array of profile hashtables from the manifest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [array]$Profiles
    )

    if (-not (Test-Path $SourcePath)) {
        Write-MigrationLog -Message "App profiles source path not found: $SourcePath" -Level Warning
        return 0
    }

    $importedCount = 0

    foreach ($profile in $Profiles) {
        if (-not $profile.Selected) { continue }

        $profileDir = Join-Path $SourcePath ($profile.Name -replace '[\\/:*?"<>|]', '_')
        if (-not (Test-Path $profileDir)) {
            Write-MigrationLog -Message "Profile directory not found for $($profile.Name), skipping" -Level Warning
            continue
        }

        # Restore files
        foreach ($filePath in $profile.Files) {
            try {
                $expanded = [System.Environment]::ExpandEnvironmentVariables($filePath)
                if ($filePath.EndsWith('\') -or $filePath.EndsWith('/')) {
                    # Directory - use Robocopy
                    $folderName = [System.IO.Path]::GetFileName($filePath.TrimEnd('\', '/'))
                    $srcDir = Join-Path $profileDir $folderName
                    if (Test-Path $srcDir) {
                        $parentDir = [System.IO.Path]::GetDirectoryName($expanded)
                        if (-not (Test-Path $parentDir)) {
                            New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
                        }
                        & robocopy $srcDir $expanded /E /R:1 /W:1 /NJH /NJS /NFL /NDL /NP 2>&1 | Out-Null
                    }
                } else {
                    # Single file
                    $srcFile = Join-Path $profileDir ([System.IO.Path]::GetFileName($filePath))
                    if (Test-Path $srcFile) {
                        $parentDir = [System.IO.Path]::GetDirectoryName($expanded)
                        if (-not (Test-Path $parentDir)) {
                            New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
                        }
                        Copy-Item -Path $srcFile -Destination $expanded -Force -ErrorAction SilentlyContinue
                    }
                }
            } catch {
                Write-MigrationLog -Message "Failed to import file $filePath for $($profile.Name): $($_.Exception.Message)" -Level Warning
            }
        }

        # Restore registry keys
        $regFiles = Get-ChildItem $profileDir -Filter '*.reg' -ErrorAction SilentlyContinue
        foreach ($regFile in $regFiles) {
            try {
                & reg import $regFile.FullName 2>&1 | Out-Null
            } catch {
                Write-MigrationLog -Message "Failed to import registry for $($profile.Name): $($_.Exception.Message)" -Level Warning
            }
        }

        $importedCount++
        Write-MigrationLog -Message "Imported app profile: $($profile.Name)" -Level Info
    }

    Write-MigrationLog -Message "App profile import complete: $importedCount profiles imported" -Level Success
    return $importedCount
}
