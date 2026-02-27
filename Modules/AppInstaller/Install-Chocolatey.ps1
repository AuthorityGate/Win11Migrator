<#
========================================================================================================
    Title:          Win11Migrator - Chocolatey Bootstrap Installer
    Filename:       Install-Chocolatey.ps1
    Description:    Installs the Chocolatey package manager if not already present on the target system.
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
    Bootstraps the Chocolatey package manager on the target machine.

.DESCRIPTION
    Checks whether Chocolatey is already installed.  If not, downloads and runs
    the official community installer script.  Verifies the installation succeeded
    by confirming that the choco command is available afterward.

.PARAMETER Force
    Re-installs Chocolatey even if it is already present.

.OUTPUTS
    [bool] - $true if Chocolatey is available after the function completes,
             $false otherwise.
#>

function Install-Chocolatey {
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    Write-MigrationLog -Message "Install-Chocolatey: Checking for existing Chocolatey installation." -Level Info

    # -----------------------------------------------------------------
    # Check if already installed
    # -----------------------------------------------------------------
    $existingChoco = Get-Command choco -ErrorAction SilentlyContinue
    if ($existingChoco -and -not $Force) {
        $chocoVersion = $null
        try {
            $chocoVersion = & choco --version 2>$null
        } catch { <# ignore #> }

        Write-MigrationLog -Message "Install-Chocolatey: Chocolatey is already installed (version: $chocoVersion)." -Level Info
        return $true
    }

    # -----------------------------------------------------------------
    # Require admin privileges for installation
    # -----------------------------------------------------------------
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdmin) {
        Write-MigrationLog -Message "Install-Chocolatey: Administrator privileges are required to install Chocolatey." -Level Error
        return $false
    }

    # -----------------------------------------------------------------
    # Download and execute the official installer
    # -----------------------------------------------------------------
    Write-MigrationLog -Message "Install-Chocolatey: Downloading and running the Chocolatey installer." -Level Info

    try {
        # Temporarily allow running downloaded scripts in this process scope
        $previousPolicy = Get-ExecutionPolicy -Scope Process
        Set-ExecutionPolicy Bypass -Scope Process -Force

        # Download the installer script
        $installScriptUrl = 'https://community.chocolatey.org/install.ps1'
        $webClient = New-Object System.Net.WebClient

        # Respect TLS 1.2 (required by chocolatey.org)
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

        $installScript = $webClient.DownloadString($installScriptUrl)

        if ([string]::IsNullOrWhiteSpace($installScript)) {
            Write-MigrationLog -Message "Install-Chocolatey: Downloaded install script is empty." -Level Error
            return $false
        }

        Write-MigrationLog -Message "Install-Chocolatey: Installer script downloaded ($($installScript.Length) chars). Executing." -Level Debug

        # Execute the installer
        Invoke-Expression $installScript

        # Restore execution policy
        try {
            Set-ExecutionPolicy $previousPolicy -Scope Process -Force -ErrorAction SilentlyContinue
        } catch { <# ignore -- Bypass is harmless at process scope #> }
    }
    catch {
        Write-MigrationLog -Message "Install-Chocolatey: Exception during installation: $($_.Exception.Message)" -Level Error

        # Attempt to restore execution policy on failure
        try {
            Set-ExecutionPolicy $previousPolicy -Scope Process -Force -ErrorAction SilentlyContinue
        } catch { <# ignore #> }

        return $false
    }

    # -----------------------------------------------------------------
    # Refresh PATH so the current session can find choco
    # -----------------------------------------------------------------
    $chocoInstallPath = $env:ChocolateyInstall
    if (-not $chocoInstallPath) {
        $chocoInstallPath = "$env:ProgramData\chocolatey"
    }

    $chocoBin = Join-Path $chocoInstallPath 'bin'
    if (Test-Path $chocoBin) {
        if ($env:PATH -notlike "*$chocoBin*") {
            $env:PATH = "$chocoBin;$env:PATH"
            Write-MigrationLog -Message "Install-Chocolatey: Added '$chocoBin' to session PATH." -Level Debug
        }
    }

    # -----------------------------------------------------------------
    # Verify installation
    # -----------------------------------------------------------------
    $verifyChoco = Get-Command choco -ErrorAction SilentlyContinue
    if ($verifyChoco) {
        $installedVersion = $null
        try {
            $installedVersion = & choco --version 2>$null
        } catch { <# ignore #> }

        Write-MigrationLog -Message "Install-Chocolatey: Chocolatey installed successfully (version: $installedVersion)." -Level Success
        return $true
    }
    else {
        Write-MigrationLog -Message "Install-Chocolatey: Installation completed but 'choco' command is not available. Installation may have failed." -Level Error
        return $false
    }
}
