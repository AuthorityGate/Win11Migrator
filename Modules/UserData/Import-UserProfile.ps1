<#
========================================================================================================
    Title:          Win11Migrator - User Profile Data Importer
    Filename:       Import-UserProfile.ps1
    Description:    Restores user profile data from a migration package to the target machine via Robocopy.
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
    Restores user data folders from a migration package to the target machine.
.DESCRIPTION
    Reads UserDataItem objects from a manifest, locates the exported files in the
    migration package, and restores them to the current user's profile paths using
    Robocopy. Handles path differences between source and target machines.
.PARAMETER Items
    UserDataItem[] from the migration manifest.
.PARAMETER PackagePath
    Root path of the migration package containing the exported UserData folder.
.PARAMETER TargetProfilePaths
    Optional hashtable from Get-UserProfilePaths on the target machine. If not
    provided, the function will call Get-UserProfilePaths automatically.
.OUTPUTS
    [UserDataItem[]] Updated items with ExportStatus reflecting import result.
#>

function Import-UserProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [UserDataItem[]]$Items,

        [Parameter(Mandatory)]
        [string]$PackagePath,

        [hashtable]$TargetProfilePaths,

        [switch]$PreserveACLs
    )

    Write-MigrationLog -Message "Beginning user profile import from $PackagePath" -Level Info

    # Resolve target profile paths if not supplied
    if (-not $TargetProfilePaths) {
        $TargetProfilePaths = Get-UserProfilePaths
    }

    # Robocopy settings
    $threads  = if ($script:Config -and $script:Config['RobocopyThreads'])      { $script:Config['RobocopyThreads'] }      else { 8 }
    $retries  = if ($script:Config -and $script:Config['RobocopyRetries'])       { $script:Config['RobocopyRetries'] }      else { 3 }
    $waitSec  = if ($script:Config -and $script:Config['RobocopyWaitSeconds'])   { $script:Config['RobocopyWaitSeconds'] }  else { 5 }

    $excludePatterns = @('*.tmp', '~$*', 'Thumbs.db', 'desktop.ini')
    if ($script:Config -and $script:Config['ExcludeFilePatterns']) {
        $excludePatterns = @()
        foreach ($p in $script:Config['ExcludeFilePatterns']) {
            $excludePatterns += $p.ToString()
        }
    }

    $selectedItems = $Items | Where-Object { $_.Selected }
    $totalCount = @($selectedItems).Count
    $currentIndex = 0

    Write-MigrationLog -Message "Importing $totalCount user data items" -Level Info

    foreach ($item in $Items) {
        if (-not $item.Selected) {
            $item.ExportStatus = 'Skipped'
            continue
        }

        $currentIndex++
        Write-MigrationLog -Message "Importing [$currentIndex/$totalCount]: $($item.Category) - $($item.RelativePath)" -Level Info

        # Determine source path inside the migration package
        $packageSourcePath = Join-Path $PackagePath "UserData\$($item.Category)"
        if ($item.RelativePath) {
            $packageSourcePath = Join-Path $PackagePath "UserData\$($item.RelativePath)"
        }

        if (-not (Test-Path $packageSourcePath)) {
            $item.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Package source not found: $packageSourcePath" -Level Warning
            continue
        }

        # Determine target path on this machine
        $targetPath = $null
        if ($TargetProfilePaths.ContainsKey($item.Category)) {
            $targetPath = $TargetProfilePaths[$item.Category]
        }
        else {
            # Fall back to the same relative structure under USERPROFILE
            $targetPath = Join-Path $env:USERPROFILE $item.Category
        }

        try {
            # Ensure target directory exists
            if (-not (Test-Path $targetPath)) {
                New-Item -Path $targetPath -ItemType Directory -Force | Out-Null
            }

            $sourceItem = Get-Item $packageSourcePath -ErrorAction Stop
            if ($sourceItem.PSIsContainer) {
                # Use Robocopy with /E (not /MIR) to avoid deleting existing files on target
                $robocopyArgs = @($packageSourcePath, $targetPath, '/E', "/R:$retries", "/W:$waitSec", "/MT:$threads", '/NP', '/NDL', '/NJH', '/NJS')
                if ($PreserveACLs) { $robocopyArgs += '/SEC' }
                foreach ($xf in $excludePatterns) { $robocopyArgs += '/XF'; $robocopyArgs += $xf }
                $robocopyOutput = & robocopy @robocopyArgs 2>&1
                $exitCode = $LASTEXITCODE

                if ($exitCode -lt 8) {
                    $item.ExportStatus = 'Success'
                    Write-MigrationLog -Message "Import successful: $($item.Category) -> $targetPath (exit code $exitCode)" -Level Success

                    # Attempt to restore ACLs from separate backup if available
                    if ($PreserveACLs) {
                        try {
                            $aclFile = Join-Path (Split-Path $PackagePath -Parent) "ACLs\$($item.Category).json"
                            if (Test-Path $aclFile) {
                                Import-FileACLs -ACLPath $aclFile -TargetBasePath $targetPath
                                Write-MigrationLog -Message "ACLs restored for $($item.Category)" -Level Success
                            }
                        } catch {
                            Write-MigrationLog -Message "ACL restore failed for $($item.Category): $($_.Exception.Message)" -Level Warning
                        }
                    }
                }
                else {
                    $item.ExportStatus = 'Failed'
                    $errorLines = ($robocopyOutput | Select-Object -Last 5) -join '; '
                    Write-MigrationLog -Message "Robocopy import failed for $($item.Category) with exit code $exitCode. $errorLines" -Level Error
                }
            }
            else {
                # Single file restore
                $destDir = Split-Path $targetPath -Parent
                if (-not (Test-Path $destDir)) {
                    New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                }
                Copy-Item -Path $packageSourcePath -Destination $targetPath -Force -ErrorAction Stop
                $item.ExportStatus = 'Success'
                Write-MigrationLog -Message "File imported: $packageSourcePath -> $targetPath" -Level Success
            }
        }
        catch {
            $item.ExportStatus = 'Failed'
            Write-MigrationLog -Message "Failed to import $($item.Category): $($_.Exception.Message)" -Level Error
        }

        $pctComplete = [math]::Round(($currentIndex / $totalCount) * 100, 1)
        Write-MigrationLog -Message "User data import progress: $pctComplete% ($currentIndex/$totalCount)" -Level Debug
    }

    $successCount = @($Items | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    $failCount    = @($Items | Where-Object { $_.ExportStatus -eq 'Failed' }).Count
    Write-MigrationLog -Message "User profile import complete. Success: $successCount, Failed: $failCount" -Level Info

    return $Items
}
