<#
========================================================================================================
    Title:          Win11Migrator - AppData Settings Importer
    Filename:       Import-AppDataSettings.ps1
    Description:    Restores application settings to AppData directories from a migration package.
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
    Restores AppData folders from a migration package to the target machine.
.DESCRIPTION
    Reads UserDataItem objects with Category 'AppData' from the manifest, locates
    the exported folders in the migration package, and restores them to the
    current user's %APPDATA% and %LOCALAPPDATA% directories.
.PARAMETER Items
    UserDataItem[] with Category 'AppData' from the migration manifest.
.PARAMETER PackagePath
    Root path of the migration package.
.OUTPUTS
    [UserDataItem[]] Updated items with ExportStatus reflecting import result.
#>

function Import-AppDataSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [UserDataItem[]]$Items,

        [Parameter(Mandatory)]
        [string]$PackagePath
    )

    Write-MigrationLog -Message "Beginning AppData settings import from $PackagePath" -Level Info

    # Robocopy settings
    $retries = if ($script:Config -and $script:Config['RobocopyRetries'])     { $script:Config['RobocopyRetries'] }     else { 3 }
    $waitSec = if ($script:Config -and $script:Config['RobocopyWaitSeconds']) { $script:Config['RobocopyWaitSeconds'] } else { 5 }
    $threads = if ($script:Config -and $script:Config['RobocopyThreads'])     { $script:Config['RobocopyThreads'] }     else { 8 }

    # Map label to environment paths on this machine
    $rootMap = @{
        'Roaming' = $env:APPDATA
        'Local'   = $env:LOCALAPPDATA
    }

    $appDataItems = $Items | Where-Object { $_.Category -eq 'AppData' -and $_.Selected }
    $totalCount = @($appDataItems).Count
    $currentIndex = 0

    Write-MigrationLog -Message "Importing $totalCount AppData items" -Level Info

    foreach ($item in $Items) {
        if ($item.Category -ne 'AppData' -or -not $item.Selected) {
            if ($item.Category -eq 'AppData' -and -not $item.Selected) {
                $item.ExportStatus = 'Skipped'
            }
            continue
        }

        $currentIndex++
        Write-MigrationLog -Message "Importing AppData [$currentIndex/$totalCount]: $($item.RelativePath)" -Level Info

        # Locate the source inside the migration package
        $packageSourcePath = Join-Path $PackagePath "UserData\$($item.RelativePath)"

        if (-not (Test-Path $packageSourcePath)) {
            $item.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Package source not found: $packageSourcePath" -Level Warning
            continue
        }

        # Determine target path from the RelativePath structure: AppData\<Roaming|Local>\<subfolder>
        # RelativePath format: AppData\Roaming\Microsoft\Sticky Notes  or  AppData\Local\...
        $targetPath = $null
        try {
            $pathParts = $item.RelativePath -split '\\', 3
            # pathParts[0] = 'AppData', pathParts[1] = 'Roaming'|'Local', pathParts[2] = relative sub-folder
            if ($pathParts.Count -ge 3 -and $rootMap.ContainsKey($pathParts[1])) {
                $targetPath = Join-Path $rootMap[$pathParts[1]] $pathParts[2]
            }
            else {
                # Fall back: try to reconstruct from the original SourcePath concept
                Write-MigrationLog -Message "Unable to parse AppData relative path: $($item.RelativePath). Attempting source path fallback." -Level Warning
                $targetPath = $item.SourcePath
            }
        }
        catch {
            $item.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Failed to determine target path for $($item.RelativePath): $($_.Exception.Message)" -Level Error
            continue
        }

        if (-not $targetPath) {
            $item.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Could not resolve target path for $($item.RelativePath)" -Level Error
            continue
        }

        try {
            if (-not (Test-Path $targetPath)) {
                New-Item -Path $targetPath -ItemType Directory -Force | Out-Null
            }

            # Use /E (not /MIR) to avoid deleting existing settings on the target
            $robocopyOutput = & robocopy $packageSourcePath $targetPath /E /R:$retries /W:$waitSec /MT:$threads /NP /NDL /NJH /NJS 2>&1
            $exitCode = $LASTEXITCODE

            if ($exitCode -lt 8) {
                $item.ExportStatus = 'Success'
                Write-MigrationLog -Message "AppData import successful: $($item.RelativePath) -> $targetPath" -Level Success
            }
            else {
                $item.ExportStatus = 'Failed'
                $errorLines = ($robocopyOutput | Select-Object -Last 5) -join '; '
                Write-MigrationLog -Message "AppData import failed for $($item.RelativePath), exit code $exitCode. $errorLines" -Level Error
            }
        }
        catch {
            $item.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Exception importing AppData $($item.RelativePath): $($_.Exception.Message)" -Level Error
        }
    }

    $successCount = @($Items | Where-Object { $_.Category -eq 'AppData' -and $_.ExportStatus -eq 'Success' }).Count
    $failCount    = @($Items | Where-Object { $_.Category -eq 'AppData' -and $_.ExportStatus -eq 'Failed' }).Count
    Write-MigrationLog -Message "AppData import complete. Success: $successCount, Failed: $failCount" -Level Info

    return $Items
}
