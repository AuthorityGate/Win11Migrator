<#
========================================================================================================
    Title:          Win11Migrator - Administrator Privilege Check
    Filename:       Test-AdminPrivilege.ps1
    Description:    Verifies whether the current session is running with elevated administrator privileges.
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
    Check if the current process is running with Administrator privileges.
#>

function Test-AdminPrivilege {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-AdminElevation {
    [CmdletBinding()]
    param(
        [string]$ScriptPath
    )

    if (-not (Test-AdminPrivilege)) {
        Write-MigrationLog -Message "Requesting admin elevation..." -Level Info
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
        Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
        return $true  # Indicates re-launch happened
    }
    return $false  # Already admin
}
