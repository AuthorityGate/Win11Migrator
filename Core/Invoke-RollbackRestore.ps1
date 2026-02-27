<#
========================================================================================================
    Title:          Win11Migrator - Rollback Restore Engine
    Filename:       Invoke-RollbackRestore.ps1
    Description:    Reverses a migration import by restoring registry keys and removing files added during import.
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
    Reverse a migration import using a previously created rollback snapshot.
.DESCRIPTION
    Reads the snapshot metadata and attempts to restore the pre-import state:
    1. Imports backed-up .reg files to restore registry keys.
    2. Compares current files against pre-import fingerprints and removes files that were
       added by the import (files not present in the snapshot fingerprint).
    Note: Full file content rollback is not possible since the snapshot stores only
    fingerprints, not file copies. Modified files cannot be reverted without a full backup.
.PARAMETER SnapshotPath
    Path to the rollback snapshot directory created by New-RollbackSnapshot.
.OUTPUTS
    [hashtable] with Success, RegistryKeysRestored, FilesRemoved, and Warnings.
#>

function Invoke-RollbackRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SnapshotPath
    )

    Write-MigrationLog -Message "Beginning rollback restore from: $SnapshotPath" -Level Info

    $registryKeysRestored = 0
    $filesRemoved = 0
    $warnings = @()
    $success = $true

    # Validate snapshot exists
    $metadataPath = Join-Path $SnapshotPath 'snapshot-metadata.json'
    if (-not (Test-Path $metadataPath)) {
        Write-MigrationLog -Message "Snapshot metadata not found: $metadataPath" -Level Error
        return @{
            Success              = $false
            RegistryKeysRestored = 0
            FilesRemoved         = 0
            Warnings             = @("Snapshot metadata not found at $metadataPath")
        }
    }

    # Load metadata
    try {
        $metadata = Get-Content $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-MigrationLog -Message "Snapshot loaded: created $($metadata.Timestamp) on $($metadata.ComputerName)" -Level Info
    }
    catch {
        Write-MigrationLog -Message "Failed to read snapshot metadata: $($_.Exception.Message)" -Level Error
        return @{
            Success              = $false
            RegistryKeysRestored = 0
            FilesRemoved         = 0
            Warnings             = @("Failed to parse snapshot metadata: $($_.Exception.Message)")
        }
    }

    # --- 1. Restore registry keys ---
    $regSnapshotDir = Join-Path $SnapshotPath 'RegistryBackups'
    if (Test-Path $regSnapshotDir) {
        $regFiles = @(Get-ChildItem -Path $regSnapshotDir -Filter '*.reg' -ErrorAction SilentlyContinue)

        foreach ($regFile in $regFiles) {
            try {
                Write-MigrationLog -Message "Restoring registry from: $($regFile.Name)" -Level Info
                $regOutput = & reg import $regFile.FullName 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $registryKeysRestored++
                    Write-MigrationLog -Message "Registry restored: $($regFile.Name)" -Level Success
                }
                else {
                    $errorText = ($regOutput | Out-String).Trim()
                    Write-MigrationLog -Message "Registry import failed for $($regFile.Name): $errorText" -Level Warning
                    $warnings += "Failed to import registry: $($regFile.Name)"
                }
            }
            catch {
                Write-MigrationLog -Message "Error restoring registry $($regFile.Name): $($_.Exception.Message)" -Level Warning
                $warnings += "Exception restoring registry: $($regFile.Name)"
            }
        }

        # Also handle JSON-format registry backups
        $jsonRegFiles = @(Get-ChildItem -Path $regSnapshotDir -Filter '*.json' -ErrorAction SilentlyContinue)

        foreach ($jsonFile in $jsonRegFiles) {
            try {
                Write-MigrationLog -Message "Restoring registry from JSON: $($jsonFile.Name)" -Level Info
                $regData = Get-Content $jsonFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json

                # Reconstruct the registry path from the filename
                $regPathName = [System.IO.Path]::GetFileNameWithoutExtension($jsonFile.Name)
                # Reverse the safe-name encoding: underscores were originally backslashes, colons, etc.
                # We need the original path from the metadata
                $originalPaths = @()
                if ($metadata.RegistryPaths) {
                    $originalPaths = @($metadata.RegistryPaths)
                }

                # Find the matching original registry path
                $matchedPath = $null
                foreach ($origPath in $originalPaths) {
                    $safeName = ($origPath -replace '[\\/:*?"<>|]', '_').TrimStart('_')
                    if ($safeName -eq $regPathName) {
                        $matchedPath = $origPath
                        break
                    }
                }

                if ($matchedPath -and (Test-Path "Registry::$($matchedPath -replace '^HKCU:\\','HKCU\' -replace '^HKLM:\\','HKLM\')")) {
                    # Restore each property
                    $regData.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object {
                        try {
                            Set-ItemProperty -Path $matchedPath -Name $_.Name -Value $_.Value -ErrorAction Stop
                        }
                        catch {
                            $warnings += "Failed to restore registry property: $matchedPath\$($_.Name)"
                        }
                    }
                    $registryKeysRestored++
                    Write-MigrationLog -Message "Registry restored from JSON: $matchedPath" -Level Success
                }
                else {
                    $warnings += "Could not map JSON backup to registry path: $($jsonFile.Name)"
                    Write-MigrationLog -Message "Could not resolve registry path for JSON backup: $($jsonFile.Name)" -Level Warning
                }
            }
            catch {
                Write-MigrationLog -Message "Error restoring JSON registry $($jsonFile.Name): $($_.Exception.Message)" -Level Warning
                $warnings += "Exception restoring JSON registry: $($jsonFile.Name)"
            }
        }
    }
    else {
        Write-MigrationLog -Message "No registry backups found in snapshot" -Level Debug
    }

    # --- 2. Remove files added by the import ---
    $dataSnapshotDir = Join-Path $SnapshotPath 'UserDataFingerprints'
    if (Test-Path $dataSnapshotDir) {
        $fingerprintFiles = @(Get-ChildItem -Path $dataSnapshotDir -Filter '*.json' -ErrorAction SilentlyContinue)

        # Build a mapping from safe names back to original paths
        $originalDataPaths = @()
        if ($metadata.UserDataPaths) {
            $originalDataPaths = @($metadata.UserDataPaths)
        }

        foreach ($fpFile in $fingerprintFiles) {
            try {
                $fpName = [System.IO.Path]::GetFileNameWithoutExtension($fpFile.Name)

                # Find the matching original data path
                $matchedDataPath = $null
                foreach ($origPath in $originalDataPaths) {
                    $safeName = ($origPath -replace '[\\/:*?"<>|]', '_').TrimStart('_')
                    if ($safeName -eq $fpName) {
                        $matchedDataPath = $origPath
                        break
                    }
                }

                if (-not $matchedDataPath) {
                    Write-MigrationLog -Message "Could not resolve original path for fingerprint: $($fpFile.Name)" -Level Warning
                    $warnings += "Unresolved fingerprint file: $($fpFile.Name)"
                    continue
                }

                if (-not (Test-Path $matchedDataPath)) {
                    Write-MigrationLog -Message "Original data path no longer exists: $matchedDataPath" -Level Warning
                    continue
                }

                # Load pre-import fingerprint
                $rawFp = Get-Content $fpFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $preImportPaths = @{}
                foreach ($f in $rawFp.Files) {
                    $preImportPaths[$f.RelativePath] = $true
                }

                # Scan current files and find ones that were NOT in the pre-import fingerprint
                $currentFiles = @(Get-ChildItem -Path $matchedDataPath -Recurse -File -ErrorAction SilentlyContinue)
                $resolvedRoot = (Resolve-Path $matchedDataPath).Path

                foreach ($currentFile in $currentFiles) {
                    $relativePath = $currentFile.FullName.Substring($resolvedRoot.Length).TrimStart('\', '/')

                    if (-not $preImportPaths.ContainsKey($relativePath)) {
                        # This file was added by the import - remove it
                        try {
                            Remove-Item -Path $currentFile.FullName -Force -ErrorAction Stop
                            $filesRemoved++
                        }
                        catch {
                            Write-MigrationLog -Message "Failed to remove imported file: $($currentFile.FullName)" -Level Warning
                            $warnings += "Could not remove: $($currentFile.FullName)"
                        }
                    }
                }

                Write-MigrationLog -Message "Rollback file cleanup complete for: $matchedDataPath" -Level Info
            }
            catch {
                Write-MigrationLog -Message "Error during file rollback for $($fpFile.Name): $($_.Exception.Message)" -Level Warning
                $warnings += "File rollback error: $($fpFile.Name)"
            }
        }

        # Note about limitations
        Write-MigrationLog -Message "Note: Files that were MODIFIED by the import cannot be reverted without a full backup. Only files ADDED by the import have been removed." -Level Warning
        $warnings += "Modified files cannot be reverted (snapshot contains fingerprints only, not file copies)"
    }
    else {
        Write-MigrationLog -Message "No user data fingerprints found in snapshot" -Level Debug
    }

    # Summary
    if ($warnings.Count -gt 0) {
        Write-MigrationLog -Message "Rollback completed with $($warnings.Count) warning(s)" -Level Warning
    }
    else {
        Write-MigrationLog -Message "Rollback completed successfully" -Level Success
    }
    Write-MigrationLog -Message "Rollback summary: $registryKeysRestored registry keys restored, $filesRemoved files removed" -Level Info

    return @{
        Success              = $success
        RegistryKeysRestored = $registryKeysRestored
        FilesRemoved         = $filesRemoved
        Warnings             = $warnings
    }
}
