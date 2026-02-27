<#
========================================================================================================
    Title:          Win11Migrator - Retry Logic Utility
    Filename:       Invoke-WithRetry.ps1
    Description:    Provides retry-with-backoff wrapper for transient operation failures.
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
    Generic retry wrapper for operations that may transiently fail.
#>

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [int]$MaxRetries = 3,

        [int]$DelaySeconds = 5,

        [string]$OperationName = "Operation",

        [scriptblock]$OnRetry
    )

    $attempt = 0
    $lastError = $null

    while ($attempt -le $MaxRetries) {
        try {
            if ($attempt -gt 0) {
                Write-MigrationLog -Message "$OperationName - Retry attempt $attempt of $MaxRetries" -Level Warning
                Start-Sleep -Seconds $DelaySeconds
                if ($OnRetry) { & $OnRetry }
            }
            $result = & $ScriptBlock
            if ($attempt -gt 0) {
                Write-MigrationLog -Message "$OperationName - Succeeded on retry $attempt" -Level Success
            }
            return $result
        } catch {
            $lastError = $_
            $attempt++
            if ($attempt -le $MaxRetries) {
                Write-MigrationLog -Message "$OperationName - Failed (attempt $attempt): $($_.Exception.Message)" -Level Warning
            }
        }
    }

    Write-MigrationLog -Message "$OperationName - All $MaxRetries retries exhausted. Last error: $($lastError.Exception.Message)" -Level Error
    throw $lastError
}
