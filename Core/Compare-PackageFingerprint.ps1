<#
========================================================================================================
    Title:          Win11Migrator - Package Fingerprint Comparator
    Filename:       Compare-PackageFingerprint.ps1
    Description:    Compares two directory fingerprints to identify added, deleted, modified, and unchanged files.
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
    Diff two fingerprints to determine file-level changes between snapshots.
.DESCRIPTION
    Accepts two fingerprint hashtables (as produced by Get-PackageFingerprint) and classifies
    every file as Added, Deleted, Modified, or Unchanged based on relative path and SHA256 hash.
.PARAMETER OldFingerprint
    The baseline (earlier) fingerprint hashtable.
.PARAMETER NewFingerprint
    The current (later) fingerprint hashtable.
.OUTPUTS
    [hashtable] with Added, Deleted, Modified, Unchanged arrays and summary counts/sizes.
#>

function Compare-PackageFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$OldFingerprint,

        [Parameter(Mandatory)]
        [hashtable]$NewFingerprint
    )

    Write-MigrationLog -Message "Comparing fingerprints: Old=$($OldFingerprint.Path) vs New=$($NewFingerprint.Path)" -Level Info

    # Build lookup hashtables keyed by RelativePath
    $oldLookup = @{}
    foreach ($file in $OldFingerprint.Files) {
        $oldLookup[$file.RelativePath] = $file
    }

    $newLookup = @{}
    foreach ($file in $NewFingerprint.Files) {
        $newLookup[$file.RelativePath] = $file
    }

    $added     = @()
    $deleted   = @()
    $modified  = @()
    $unchanged = @()

    # Check files in New fingerprint against Old
    foreach ($relPath in $newLookup.Keys) {
        $newFile = $newLookup[$relPath]

        if (-not $oldLookup.ContainsKey($relPath)) {
            # File exists in New but not Old = Added
            $added += $newFile
        }
        else {
            $oldFile = $oldLookup[$relPath]
            if ($newFile.Hash -ne $oldFile.Hash -or $newFile.SizeBytes -ne $oldFile.SizeBytes) {
                # File exists in both but hash or size differs = Modified
                $modified += $newFile
            }
            else {
                # File identical = Unchanged
                $unchanged += $newFile
            }
        }
    }

    # Check files in Old that are missing from New = Deleted
    foreach ($relPath in $oldLookup.Keys) {
        if (-not $newLookup.ContainsKey($relPath)) {
            $deleted += $oldLookup[$relPath]
        }
    }

    # Compute size totals
    $addedSizeBytes    = [long]0
    foreach ($f in $added) { $addedSizeBytes += $f.SizeBytes }

    $modifiedSizeBytes = [long]0
    foreach ($f in $modified) { $modifiedSizeBytes += $f.SizeBytes }

    $result = @{
        Added            = $added
        Deleted          = $deleted
        Modified         = $modified
        Unchanged        = $unchanged
        AddedCount       = $added.Count
        DeletedCount     = $deleted.Count
        ModifiedCount    = $modified.Count
        UnchangedCount   = $unchanged.Count
        AddedSizeBytes   = $addedSizeBytes
        ModifiedSizeBytes = $modifiedSizeBytes
    }

    Write-MigrationLog -Message "Fingerprint diff: $($added.Count) added, $($deleted.Count) deleted, $($modified.Count) modified, $($unchanged.Count) unchanged" -Level Info

    return $result
}
