<#
========================================================================================================
    Title:          Win11Migrator - EFS Encryption Scanner
    Filename:       Test-EFSEncryption.ps1
    Description:    Scans directories for EFS-encrypted files and warns the user about migration limitations.
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
    Detects EFS-encrypted files in the specified paths and returns a summary with warnings.
.DESCRIPTION
    Recursively scans one or more directory paths for files with the Encrypted attribute
    (EFS -- Encrypting File System). Returns a summary including the list of encrypted files,
    total count, total size, and a warning message explaining that EFS-encrypted files cannot
    be migrated without the user's EFS certificate and private key.
.PARAMETER Paths
    One or more directory paths to scan for EFS-encrypted files.
.OUTPUTS
    [hashtable] with keys: HasEncryptedFiles ([bool]), EncryptedFiles ([array]),
    TotalCount ([int]), TotalSizeBytes ([long]), Warning ([string])
#>

function Test-EFSEncryption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Paths
    )

    Write-MigrationLog -Message "Starting EFS encryption scan across $($Paths.Count) path(s)" -Level Info

    $encryptedFiles = @()
    $totalSizeBytes = [long]0
    $scannedCount = 0
    $accessDeniedCount = 0

    foreach ($scanPath in $Paths) {
        if (-not (Test-Path $scanPath)) {
            Write-MigrationLog -Message "Path does not exist, skipping EFS scan: $scanPath" -Level Warning
            continue
        }

        $resolvedPath = (Resolve-Path $scanPath).Path.TrimEnd('\')
        Write-MigrationLog -Message "Scanning for EFS-encrypted files in: $resolvedPath" -Level Debug

        try {
            $items = Get-ChildItem -Path $resolvedPath -Recurse -Force -ErrorAction SilentlyContinue

            foreach ($item in $items) {
                $scannedCount++
                try {
                    # Check if the file has the Encrypted attribute (EFS)
                    if ($item.Attributes -band [System.IO.FileAttributes]::Encrypted) {
                        $relativePath = $item.FullName.Substring($resolvedPath.Length).TrimStart('\')
                        $sizeBytes = if ($item.PSIsContainer) { 0 } else { $item.Length }

                        $encryptedFiles += @{
                            FullPath     = $item.FullName
                            RelativePath = $relativePath
                            SizeBytes    = $sizeBytes
                            IsDirectory  = $item.PSIsContainer
                        }

                        $totalSizeBytes += $sizeBytes
                    }
                }
                catch {
                    $accessDeniedCount++
                    Write-MigrationLog -Message "Access denied scanning '$($item.FullName)': $($_.Exception.Message)" -Level Debug
                }
            }
        }
        catch {
            Write-MigrationLog -Message "Error scanning path '$resolvedPath': $($_.Exception.Message)" -Level Warning
        }
    }

    $totalCount = $encryptedFiles.Count
    $hasEncrypted = $totalCount -gt 0

    # Build warning message
    $warning = ''
    if ($hasEncrypted) {
        $sizeMB = [math]::Round($totalSizeBytes / 1MB, 2)
        $warning = "$totalCount EFS-encrypted file(s) detected ($sizeMB MB). " +
                   "These files cannot be migrated without the EFS certificate and private key. " +
                   "Export your EFS certificate from the source PC (certmgr.msc > Personal > Certificates) " +
                   "and import it on the target PC before attempting to access these files."
        Write-MigrationLog -Message $warning -Level Warning
    } else {
        Write-MigrationLog -Message "No EFS-encrypted files detected (scanned $scannedCount items)" -Level Info
    }

    if ($accessDeniedCount -gt 0) {
        Write-MigrationLog -Message "$accessDeniedCount file(s) could not be scanned due to access restrictions" -Level Debug
    }

    Write-MigrationLog -Message "EFS scan complete: $totalCount encrypted file(s) found across $scannedCount items scanned" -Level Success

    return @{
        HasEncryptedFiles = $hasEncrypted
        EncryptedFiles    = $encryptedFiles
        TotalCount        = $totalCount
        TotalSizeBytes    = $totalSizeBytes
        Warning           = $warning
    }
}
