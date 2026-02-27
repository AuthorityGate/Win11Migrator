<#
========================================================================================================
    Title:          Win11Migrator - File ACL Importer
    Filename:       Import-FileACLs.ps1
    Description:    Restores non-inherited file and folder ACLs from a JSON backup created by Export-FileACLs.
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
    Restores explicit ACLs from a JSON backup file to a target directory.
.DESCRIPTION
    Reads the JSON ACL backup produced by Export-FileACLs and applies each SDDL security
    descriptor to the corresponding file or folder under the target base path. Uses
    DirectorySecurity or FileSecurity depending on the item type. Tracks and reports
    success and failure counts.
.PARAMETER ACLBackupFile
    Path to the JSON file produced by Export-FileACLs.
.PARAMETER TargetBasePath
    The root directory under which ACLs will be restored (paths are resolved relative to this).
.OUTPUTS
    [hashtable] with keys: Restored ([int]), Failed ([int])
#>

function Import-FileACLs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ACLBackupFile,

        [Parameter(Mandatory)]
        [string]$TargetBasePath
    )

    Write-MigrationLog -Message "Starting ACL import from '$ACLBackupFile' to '$TargetBasePath'" -Level Info

    try {
        # Validate inputs
        if (-not (Test-Path $ACLBackupFile)) {
            Write-MigrationLog -Message "ACL backup file not found: $ACLBackupFile" -Level Error
            throw "ACL backup file not found: $ACLBackupFile"
        }

        if (-not (Test-Path $TargetBasePath)) {
            Write-MigrationLog -Message "Target base path does not exist: $TargetBasePath" -Level Error
            throw "Target base path does not exist: $TargetBasePath"
        }

        # Read and parse JSON backup
        $jsonContent = Get-Content -Path $ACLBackupFile -Raw -Encoding UTF8
        $aclEntries = $jsonContent | ConvertFrom-Json

        if (-not $aclEntries -or @($aclEntries).Count -eq 0) {
            Write-MigrationLog -Message "No ACL entries found in backup file" -Level Warning
            return @{
                Restored = 0
                Failed   = 0
            }
        }

        $totalEntries = @($aclEntries).Count
        $restoredCount = 0
        $failedCount = 0

        Write-MigrationLog -Message "Processing $totalEntries ACL entries" -Level Info

        foreach ($entry in $aclEntries) {
            try {
                # Resolve the full target path
                $relativePath = $entry.RelativePath
                if ($relativePath -eq '.') {
                    $fullPath = $TargetBasePath
                } else {
                    $fullPath = Join-Path $TargetBasePath $relativePath
                }

                # Verify the target item exists
                if (-not (Test-Path $fullPath)) {
                    Write-MigrationLog -Message "Target path does not exist, skipping ACL restore: $fullPath" -Level Debug
                    $failedCount++
                    continue
                }

                $targetItem = Get-Item -Path $fullPath -ErrorAction Stop

                # Create the appropriate security descriptor from SDDL
                if ($targetItem.PSIsContainer) {
                    $sd = New-Object System.Security.AccessControl.DirectorySecurity
                    $sd.SetSecurityDescriptorSddlForm($entry.Sddl)
                } else {
                    $sd = New-Object System.Security.AccessControl.FileSecurity
                    $sd.SetSecurityDescriptorSddlForm($entry.Sddl)
                }

                # Apply the ACL
                Set-Acl -Path $fullPath -AclObject $sd -ErrorAction Stop

                $restoredCount++
                Write-MigrationLog -Message "Restored ACL for: $relativePath" -Level Debug
            }
            catch {
                $failedCount++
                $itemPath = if ($entry.RelativePath) { $entry.RelativePath } else { '(unknown)' }
                Write-MigrationLog -Message "Failed to restore ACL for '$itemPath': $($_.Exception.Message)" -Level Warning
            }
        }

        Write-MigrationLog -Message "ACL import complete: $restoredCount restored, $failedCount failed out of $totalEntries total" -Level Success

        return @{
            Restored = $restoredCount
            Failed   = $failedCount
        }
    }
    catch {
        Write-MigrationLog -Message "ACL import failed: $($_.Exception.Message)" -Level Error
        throw
    }
}
