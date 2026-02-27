<#
========================================================================================================
    Title:          Win11Migrator - AppData Settings Exporter
    Filename:       Export-AppDataSettings.ps1
    Description:    Exports application settings from AppData (Local/Roaming) directories for migration.
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
    Exports selected AppData folders for migration.
.DESCRIPTION
    Copies folders listed in the AppDataInclude configuration from both
    %APPDATA% (Roaming) and %LOCALAPPDATA% (Local) to the migration package.
    Returns UserDataItem[] representing what was exported.
.PARAMETER AppDataFolders
    Array of relative AppData folder paths to export. If not specified, reads
    from the AppDataInclude config setting.
.PARAMETER OutputDirectory
    Root of the migration package.
.OUTPUTS
    [UserDataItem[]] Items representing exported AppData settings.
#>

function Export-AppDataSettings {
    [CmdletBinding()]
    param(
        [string[]]$AppDataFolders,

        [Parameter(Mandatory)]
        [string]$OutputDirectory
    )

    Write-MigrationLog -Message "Beginning AppData settings export" -Level Info

    # Load folder list from config if not supplied
    if (-not $AppDataFolders) {
        if ($script:Config -and $script:Config['AppDataInclude']) {
            $AppDataFolders = @()
            foreach ($f in $script:Config['AppDataInclude']) {
                $AppDataFolders += $f.ToString()
            }
        }
    }

    if (-not $AppDataFolders -or $AppDataFolders.Count -eq 0) {
        Write-MigrationLog -Message "No AppData folders configured for export" -Level Warning
        return @()
    }

    $exportedItems = [System.Collections.Generic.List[UserDataItem]]::new()

    # Robocopy settings
    $retries = if ($script:Config -and $script:Config['RobocopyRetries'])     { $script:Config['RobocopyRetries'] }     else { 3 }
    $waitSec = if ($script:Config -and $script:Config['RobocopyWaitSeconds']) { $script:Config['RobocopyWaitSeconds'] } else { 5 }
    $threads = if ($script:Config -and $script:Config['RobocopyThreads'])     { $script:Config['RobocopyThreads'] }     else { 8 }

    # Search both Roaming and Local AppData
    $appDataRoots = @(
        @{ Label = 'Roaming'; Path = $env:APPDATA }
        @{ Label = 'Local';   Path = $env:LOCALAPPDATA }
    )

    foreach ($folder in $AppDataFolders) {
        foreach ($root in $appDataRoots) {
            $sourcePath = Join-Path $root.Path $folder

            if (-not (Test-Path $sourcePath)) {
                Write-MigrationLog -Message "AppData folder not found ($($root.Label)): $sourcePath" -Level Debug
                continue
            }

            $relativePath = "AppData\$($root.Label)\$folder"
            $destPath = Join-Path $OutputDirectory $relativePath

            Write-MigrationLog -Message "Exporting AppData: $sourcePath -> $destPath" -Level Info

            $item = [UserDataItem]::new()
            $item.SourcePath    = $sourcePath
            $item.RelativePath  = $relativePath
            $item.Category      = 'AppData'
            $item.Selected      = $true
            $item.ExportStatus  = 'Pending'

            try {
                # Calculate size
                $size = (Get-ChildItem $sourcePath -Recurse -Force -ErrorAction SilentlyContinue |
                         Measure-Object -Property Length -Sum).Sum
                $item.SizeBytes = if ($size) { $size } else { 0 }

                # Create destination
                if (-not (Test-Path $destPath)) {
                    New-Item -Path $destPath -ItemType Directory -Force | Out-Null
                }

                # Copy using Robocopy
                $robocopyOutput = & robocopy $sourcePath $destPath /MIR /R:$retries /W:$waitSec /MT:$threads /NP /NDL /NJH /NJS /XF *.tmp *.log 2>&1
                $exitCode = $LASTEXITCODE

                if ($exitCode -lt 8) {
                    $item.ExportStatus = 'Success'
                    Write-MigrationLog -Message "AppData export successful: $folder ($($root.Label))" -Level Success
                }
                else {
                    $item.ExportStatus = 'Failed'
                    $errorLines = ($robocopyOutput | Select-Object -Last 5) -join '; '
                    Write-MigrationLog -Message "AppData export failed for $folder ($($root.Label)), exit code $exitCode. $errorLines" -Level Error
                }
            }
            catch {
                $item.ExportStatus = 'Failed'
                Write-MigrationLog -Message "Exception exporting AppData $folder ($($root.Label)): $($_.Exception.Message)" -Level Error
            }

            $exportedItems.Add($item)
        }
    }

    $successCount = @($exportedItems | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "AppData export complete. $successCount of $($exportedItems.Count) items exported successfully." -Level Info

    return $exportedItems.ToArray()
}
