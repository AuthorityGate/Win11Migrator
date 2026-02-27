<#
========================================================================================================
    Title:          Win11Migrator - Incremental Profile Exporter
    Filename:       Export-IncrementalProfile.ps1
    Description:    Exports only added and modified user profile files by comparing against a previous fingerprint.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 27, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1
<#
.SYNOPSIS
    Incremental export of user profile data, copying only files that changed since the last export.
.DESCRIPTION
    Loads a previous fingerprint JSON, computes the current fingerprint for each selected UserDataItem,
    compares them, and copies only added and modified files. Saves a new fingerprint for future
    incremental runs. This dramatically reduces export time and disk usage for repeat migrations.
.PARAMETER Items
    UserDataItem[] of folders/files to export.
.PARAMETER OutputDirectory
    Root directory of the migration package where files will be stored.
.PARAMETER PreviousFingerprintFile
    Path to the fingerprint.json from the previous export.
.PARAMETER ExcludePatterns
    File patterns to exclude (e.g. *.tmp, ~$*).
.OUTPUTS
    [UserDataItem[]] Updated items with ExportStatus set.
#>

function Export-IncrementalProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [UserDataItem[]]$Items,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [Parameter(Mandatory)]
        [string]$PreviousFingerprintFile,

        [string[]]$ExcludePatterns
    )

    Write-MigrationLog -Message "Beginning incremental profile export to $OutputDirectory" -Level Info

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

    # Load previous fingerprint
    $previousFingerprint = $null
    if (Test-Path $PreviousFingerprintFile) {
        try {
            $raw = Get-Content $PreviousFingerprintFile -Raw -Encoding UTF8 | ConvertFrom-Json
            # Convert PSCustomObject back to hashtable structure
            $previousFingerprint = @{
                Path           = $raw.Path
                TotalFiles     = $raw.TotalFiles
                TotalSizeBytes = $raw.TotalSizeBytes
                GeneratedAt    = $raw.GeneratedAt
                Files          = @()
            }
            foreach ($f in $raw.Files) {
                $previousFingerprint.Files += @{
                    RelativePath     = $f.RelativePath
                    Hash             = $f.Hash
                    SizeBytes        = $f.SizeBytes
                    LastWriteTimeUtc = $f.LastWriteTimeUtc
                }
            }
            Write-MigrationLog -Message "Loaded previous fingerprint: $($previousFingerprint.TotalFiles) files from $($previousFingerprint.GeneratedAt)" -Level Info
        }
        catch {
            Write-MigrationLog -Message "Failed to load previous fingerprint, falling back to full export: $($_.Exception.Message)" -Level Warning
            $previousFingerprint = $null
        }
    }
    else {
        Write-MigrationLog -Message "No previous fingerprint found at $PreviousFingerprintFile - performing full export" -Level Warning
    }

    # Ensure output directory exists
    if (-not (Test-Path $OutputDirectory)) {
        New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
    }

    $selectedItems = $Items | Where-Object { $_.Selected }
    $totalCount    = @($selectedItems).Count
    $currentIndex  = 0

    $totalAdded    = 0
    $totalModified = 0
    $totalUnchanged = 0
    $totalSavedBytes = [long]0

    Write-MigrationLog -Message "Incremental export: $totalCount items selected" -Level Info

    foreach ($item in $Items) {
        if (-not $item.Selected) {
            $item.ExportStatus = 'Skipped'
            Write-MigrationLog -Message "Skipped (not selected): $($item.SourcePath)" -Level Debug
            continue
        }

        $currentIndex++
        Write-MigrationLog -Message "Incremental export [$currentIndex/$totalCount]: $($item.Category) - $($item.SourcePath)" -Level Info

        # Validate source
        if (-not (Test-Path $item.SourcePath)) {
            $item.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Source path does not exist: $($item.SourcePath)" -Level Warning
            continue
        }

        # Build destination path
        $destPath = Join-Path $OutputDirectory $item.Category
        if ($item.RelativePath) {
            $destPath = Join-Path $OutputDirectory $item.RelativePath
        }

        try {
            # Generate current fingerprint for this item
            $currentFingerprint = Get-PackageFingerprint -Path $item.SourcePath

            if ($previousFingerprint) {
                # Build a sub-fingerprint from the previous data that matches this item's path
                $prevSubFingerprint = @{
                    Path           = $item.SourcePath
                    Files          = @()
                    TotalFiles     = 0
                    TotalSizeBytes = [long]0
                    GeneratedAt    = $previousFingerprint.GeneratedAt
                }

                # Match previous files that belong to this source path
                # Previous fingerprint is rooted at the overall package; current is rooted at the item source
                foreach ($f in $previousFingerprint.Files) {
                    $prevSubFingerprint.Files += $f
                    $prevSubFingerprint.TotalFiles++
                    $prevSubFingerprint.TotalSizeBytes += $f.SizeBytes
                }

                # Compare fingerprints
                $diff = Compare-PackageFingerprint -OldFingerprint $prevSubFingerprint -NewFingerprint $currentFingerprint

                $filesToCopy = @()
                $filesToCopy += $diff.Added
                $filesToCopy += $diff.Modified

                $totalAdded    += $diff.AddedCount
                $totalModified += $diff.ModifiedCount
                $totalUnchanged += $diff.UnchangedCount

                # Calculate bytes saved by not copying unchanged files
                foreach ($f in $diff.Unchanged) {
                    $totalSavedBytes += $f.SizeBytes
                }

                if ($filesToCopy.Count -eq 0) {
                    $item.ExportStatus = 'Success'
                    Write-MigrationLog -Message "No changes detected for $($item.Category) - skipping copy" -Level Info
                    continue
                }

                Write-MigrationLog -Message "$($item.Category): copying $($filesToCopy.Count) changed files ($($diff.AddedCount) added, $($diff.ModifiedCount) modified, $($diff.UnchangedCount) unchanged)" -Level Info

                # Copy only added and modified files
                foreach ($fileEntry in $filesToCopy) {
                    $sourceFile = Join-Path $item.SourcePath $fileEntry.RelativePath
                    $destFile   = Join-Path $destPath $fileEntry.RelativePath

                    # Check exclude patterns
                    $excluded = $false
                    foreach ($pattern in $ExcludePatterns) {
                        if ((Split-Path $fileEntry.RelativePath -Leaf) -like $pattern) {
                            $excluded = $true
                            break
                        }
                    }
                    if ($excluded) { continue }

                    # Ensure destination directory exists
                    $destFileDir = Split-Path $destFile -Parent
                    if (-not (Test-Path $destFileDir)) {
                        New-Item -Path $destFileDir -ItemType Directory -Force | Out-Null
                    }

                    Copy-Item -Path $sourceFile -Destination $destFile -Force -ErrorAction Stop
                }

                $item.ExportStatus = 'Success'
            }
            else {
                # No previous fingerprint - full copy via Robocopy
                Write-MigrationLog -Message "Full copy (no previous fingerprint) for $($item.Category)" -Level Info

                if (-not (Test-Path $destPath)) {
                    New-Item -Path $destPath -ItemType Directory -Force | Out-Null
                }

                $sourceItem = Get-Item $item.SourcePath -ErrorAction Stop
                if ($sourceItem.PSIsContainer) {
                    $retries = if ($script:Config -and $script:Config['RobocopyRetries']) { $script:Config['RobocopyRetries'] } else { 3 }
                    $waitSec = if ($script:Config -and $script:Config['RobocopyWaitSeconds']) { $script:Config['RobocopyWaitSeconds'] } else { 5 }
                    $threads = if ($script:Config -and $script:Config['RobocopyThreads']) { $script:Config['RobocopyThreads'] } else { 8 }

                    $robocopyOutput = & robocopy $item.SourcePath $destPath /MIR /R:$retries /W:$waitSec /MT:$threads /NP /NDL /NJH /NJS /XF @ExcludePatterns 2>&1
                    $exitCode = $LASTEXITCODE

                    if ($exitCode -lt 8) {
                        $item.ExportStatus = 'Success'
                        $totalAdded += $currentFingerprint.TotalFiles
                    }
                    else {
                        $item.ExportStatus = 'Failed'
                        $errorLines = ($robocopyOutput | Select-Object -Last 5) -join '; '
                        Write-MigrationLog -Message "Robocopy failed for $($item.SourcePath) with exit code $exitCode. Output: $errorLines" -Level Error
                    }
                }
                else {
                    $destDir = Split-Path $destPath -Parent
                    if (-not (Test-Path $destDir)) {
                        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -Path $item.SourcePath -Destination $destPath -Force -ErrorAction Stop
                    $item.ExportStatus = 'Success'
                    $totalAdded++
                }
            }
        }
        catch {
            $item.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Failed incremental export of $($item.SourcePath): $($_.Exception.Message)" -Level Error
        }

        # Progress reporting
        $pctComplete = [math]::Round(($currentIndex / $totalCount) * 100, 1)
        Write-MigrationLog -Message "Incremental export progress: $pctComplete% ($currentIndex/$totalCount)" -Level Debug
    }

    # Save new combined fingerprint for future incremental runs
    $newFingerprintPath = Join-Path $OutputDirectory 'fingerprint.json'
    try {
        # Build combined fingerprint from all selected items
        $combinedFingerprint = @{
            Path           = $OutputDirectory
            Files          = @()
            TotalFiles     = 0
            TotalSizeBytes = [long]0
            GeneratedAt    = (Get-Date).ToUniversalTime().ToString('o')
        }

        foreach ($item in ($Items | Where-Object { $_.Selected -and $_.ExportStatus -eq 'Success' })) {
            if (Test-Path $item.SourcePath) {
                $fp = Get-PackageFingerprint -Path $item.SourcePath
                $combinedFingerprint.Files += $fp.Files
                $combinedFingerprint.TotalFiles += $fp.TotalFiles
                $combinedFingerprint.TotalSizeBytes += $fp.TotalSizeBytes
            }
        }

        $combinedFingerprint | ConvertTo-Json -Depth 5 | Set-Content -Path $newFingerprintPath -Encoding UTF8 -Force
        Write-MigrationLog -Message "New fingerprint saved to: $newFingerprintPath" -Level Info
    }
    catch {
        Write-MigrationLog -Message "Failed to save new fingerprint: $($_.Exception.Message)" -Level Warning
    }

    # Summary
    $savedMB = [math]::Round($totalSavedBytes / 1MB, 2)
    $successCount = @($Items | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    $failCount    = @($Items | Where-Object { $_.ExportStatus -eq 'Failed' }).Count
    Write-MigrationLog -Message "Incremental export complete: $totalAdded added, $totalModified modified, $totalUnchanged unchanged (saved $savedMB MB). Success: $successCount, Failed: $failCount" -Level Info

    return $Items
}
