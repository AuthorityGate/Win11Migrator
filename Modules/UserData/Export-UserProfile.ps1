<#
========================================================================================================
    Title:          Win11Migrator - User Profile Data Exporter
    Filename:       Export-UserProfile.ps1
    Description:    Exports user profile data (Desktop, Documents, Downloads, etc.) via Robocopy to the migration package.
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
    Exports selected user data folders using Robocopy with progress tracking.
.DESCRIPTION
    Takes an array of UserDataItem objects and an output directory. Each selected item
    is copied via Robocopy with multi-threaded, retry-capable flags. Progress is parsed
    from Robocopy output and each item's ExportStatus is updated accordingly.
.PARAMETER Items
    UserDataItem[] of folders/files to export.
.PARAMETER OutputDirectory
    Root directory of the migration package where files will be stored.
.PARAMETER ExcludePatterns
    File patterns to exclude (e.g. *.tmp, ~$*). Defaults come from config.
.OUTPUTS
    [UserDataItem[]] Updated items with ExportStatus set.
#>

function Export-UserProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [UserDataItem[]]$Items,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [string[]]$ExcludePatterns,

        [switch]$PreserveACLs
    )

    Write-MigrationLog -Message "Beginning user profile export to $OutputDirectory" -Level Info

    # Load default exclude patterns from config if not supplied
    if (-not $ExcludePatterns -and $script:Config -and $script:Config['ExcludeFilePatterns']) {
        $ExcludePatterns = @()
        foreach ($p in $script:Config['ExcludeFilePatterns']) {
            $ExcludePatterns += $p.ToString()
        }
    }
    if (-not $ExcludePatterns) {
        $ExcludePatterns = @('*.tmp', '~$*', 'Thumbs.db', 'desktop.ini', '*.log')
    }

    # Robocopy settings
    $threads  = if ($script:Config -and $script:Config['RobocopyThreads'])      { $script:Config['RobocopyThreads'] }      else { 8 }
    $retries  = if ($script:Config -and $script:Config['RobocopyRetries'])       { $script:Config['RobocopyRetries'] }      else { 3 }
    $waitSec  = if ($script:Config -and $script:Config['RobocopyWaitSeconds'])   { $script:Config['RobocopyWaitSeconds'] }  else { 5 }

    $selectedItems = $Items | Where-Object { $_.Selected }
    $totalCount = @($selectedItems).Count
    $currentIndex = 0

    Write-MigrationLog -Message "Exporting $totalCount user data items" -Level Info

    foreach ($item in $Items) {
        if (-not $item.Selected) {
            $item.ExportStatus = 'Skipped'
            Write-MigrationLog -Message "Skipped (not selected): $($item.SourcePath)" -Level Debug
            continue
        }

        $currentIndex++
        Write-MigrationLog -Message "Exporting [$currentIndex/$totalCount]: $($item.Category) - $($item.SourcePath)" -Level Info

        # Validate source
        if (-not (Test-Path $item.SourcePath)) {
            $item.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Source path does not exist: $($item.SourcePath)" -Level Warning
            continue
        }

        # Build destination path preserving the relative structure
        # $OutputDirectory is already the UserData subdirectory of the package
        $destPath = Join-Path $OutputDirectory $item.Category
        if ($item.RelativePath) {
            $destPath = Join-Path $OutputDirectory $item.RelativePath
        }

        try {
            # Ensure destination directory exists
            if (-not (Test-Path $destPath)) {
                New-Item -Path $destPath -ItemType Directory -Force | Out-Null
            }

            $sourcePath = $item.SourcePath

            # Determine if source is a file or directory
            $sourceItem = Get-Item $sourcePath -ErrorAction Stop
            if ($sourceItem.PSIsContainer) {
                # Directory copy via Robocopy
                Write-MigrationLog -Message "Robocopy: $sourcePath -> $destPath" -Level Debug

                $robocopyArgs = @($sourcePath, $destPath, '/MIR', "/R:$retries", "/W:$waitSec", "/MT:$threads", '/NP', '/NDL', '/NJH', '/NJS')
                if ($PreserveACLs) { $robocopyArgs += '/SEC' }
                foreach ($xf in $ExcludePatterns) { $robocopyArgs += '/XF'; $robocopyArgs += $xf }
                $robocopyOutput = & robocopy @robocopyArgs 2>&1
                $exitCode = $LASTEXITCODE

                # Robocopy exit codes: 0-7 are success/informational, 8+ are errors
                if ($exitCode -lt 8) {
                    $item.ExportStatus = 'Success'
                    Write-MigrationLog -Message "Export successful: $($item.Category) (robocopy exit code $exitCode)" -Level Success

                    # Export ACLs separately if PreserveACLs is enabled
                    if ($PreserveACLs) {
                        try {
                            Export-FileACLs -SourcePath $sourcePath -OutputPath (Join-Path $OutputDirectory "ACLs\$($item.Category).json")
                            Write-MigrationLog -Message "ACLs exported for $($item.Category)" -Level Success
                        } catch {
                            Write-MigrationLog -Message "ACL export failed for $($item.Category): $($_.Exception.Message)" -Level Warning
                        }
                    }
                }
                else {
                    $item.ExportStatus = 'Failed'
                    $errorLines = ($robocopyOutput | Select-Object -Last 5) -join '; '
                    Write-MigrationLog -Message "Robocopy failed for $($item.SourcePath) with exit code $exitCode. Output: $errorLines" -Level Error
                }
            }
            else {
                # Single file copy
                $destDir = Split-Path $destPath -Parent
                if (-not (Test-Path $destDir)) {
                    New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                }
                Copy-Item -Path $sourcePath -Destination $destPath -Force -ErrorAction Stop
                $item.ExportStatus = 'Success'
                Write-MigrationLog -Message "File exported: $sourcePath" -Level Success
            }
        }
        catch {
            $item.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Failed to export $($item.SourcePath): $($_.Exception.Message)" -Level Error
        }

        # Report overall progress
        $pctComplete = [math]::Round(($currentIndex / $totalCount) * 100, 1)
        Write-MigrationLog -Message "User data export progress: $pctComplete% ($currentIndex/$totalCount)" -Level Debug
    }

    $successCount = @($Items | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    $failCount    = @($Items | Where-Object { $_.ExportStatus -eq 'Failed' }).Count
    Write-MigrationLog -Message "User profile export complete. Success: $successCount, Failed: $failCount, Skipped: $($totalCount - $successCount - $failCount)" -Level Info

    return $Items
}
