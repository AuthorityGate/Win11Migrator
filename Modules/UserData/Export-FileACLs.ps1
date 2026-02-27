<#
========================================================================================================
    Title:          Win11Migrator - File ACL Exporter
    Filename:       Export-FileACLs.ps1
    Description:    Backs up non-inherited (explicit) file and folder ACLs as SDDL strings to a JSON file.
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
    Exports explicit (non-inherited) ACLs from a directory tree to a JSON backup file.
.DESCRIPTION
    Recursively scans the specified source path, retrieves ACLs for each file and folder,
    filters to only non-inherited (explicit) ACEs, and saves the relative path, SDDL string,
    and owner for each entry to a JSON file. This backup can later be restored with Import-FileACLs.
.PARAMETER SourcePath
    The root directory to scan for explicit ACLs.
.PARAMETER OutputFile
    The path to write the JSON ACL backup file.
.OUTPUTS
    [hashtable] with keys: Count ([int]), OutputFile ([string])
#>

function Export-FileACLs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$OutputFile
    )

    Write-MigrationLog -Message "Starting ACL export from '$SourcePath'" -Level Info

    try {
        # Validate source path
        if (-not (Test-Path $SourcePath)) {
            Write-MigrationLog -Message "Source path does not exist: $SourcePath" -Level Error
            throw "Source path does not exist: $SourcePath"
        }

        # Normalize the source path for consistent relative path computation
        $resolvedSource = (Resolve-Path $SourcePath).Path.TrimEnd('\')

        # Collect all files and folders recursively
        $items = @()
        $items += Get-Item -Path $resolvedSource -ErrorAction SilentlyContinue
        $items += Get-ChildItem -Path $resolvedSource -Recurse -Force -ErrorAction SilentlyContinue

        $aclEntries = @()
        $scannedCount = 0
        $errorCount = 0

        foreach ($item in $items) {
            $scannedCount++
            try {
                $acl = Get-Acl -Path $item.FullName -ErrorAction Stop

                # Filter to only non-inherited (explicit) ACEs
                $explicitAces = $acl.Access | Where-Object { -not $_.IsInherited }

                if ($explicitAces -and @($explicitAces).Count -gt 0) {
                    # Compute relative path from the source root
                    $relativePath = $item.FullName.Substring($resolvedSource.Length).TrimStart('\')
                    if ([string]::IsNullOrEmpty($relativePath)) {
                        $relativePath = '.'
                    }

                    $aclEntries += @{
                        RelativePath = $relativePath
                        Sddl         = $acl.Sddl
                        Owner        = $acl.Owner
                        IsDirectory  = $item.PSIsContainer
                    }
                }
            }
            catch {
                $errorCount++
                Write-MigrationLog -Message "Cannot read ACL for '$($item.FullName)': $($_.Exception.Message)" -Level Debug
            }
        }

        # Ensure the output directory exists
        $outputDir = Split-Path $OutputFile -Parent
        if ($outputDir -and -not (Test-Path $outputDir)) {
            New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        }

        # Write ACL entries to JSON
        $aclEntries | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputFile -Encoding UTF8

        Write-MigrationLog -Message "ACL export complete: $($aclEntries.Count) items with explicit ACLs found (scanned $scannedCount, errors $errorCount)" -Level Success

        return @{
            Count      = $aclEntries.Count
            OutputFile = $OutputFile
        }
    }
    catch {
        Write-MigrationLog -Message "ACL export failed: $($_.Exception.Message)" -Level Error
        throw
    }
}
