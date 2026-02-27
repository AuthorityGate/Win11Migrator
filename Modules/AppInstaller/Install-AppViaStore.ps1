<#
========================================================================================================
    Title:          Win11Migrator - Microsoft Store Application Installer
    Filename:       Install-AppViaStore.ps1
    Description:    Installs an application from the Microsoft Store using PowerShell APIs.
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
    Installs a Microsoft Store application using winget with the msstore source.

.DESCRIPTION
    Uses winget's msstore source to install a Store app by its Store ID.
    If the winget msstore source fails (common when Store is not fully configured
    or the app is not available via winget), falls back to opening the Microsoft
    Store page in the browser so the user can install manually.

.PARAMETER App
    A [MigrationApp] instance whose PackageId contains the Microsoft Store app ID
    (e.g. "9NBLGGH4NNS1").

.PARAMETER TimeoutSeconds
    Maximum seconds to wait for the installer to finish.
    Defaults to the SilentInstallTimeout value in AppSettings.json (600).

.OUTPUTS
    [MigrationApp] - the same object with InstallStatus and InstallError updated.
#>

function Install-AppViaStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [MigrationApp]$App,

        [int]$TimeoutSeconds = 600
    )

    Write-MigrationLog -Message "Store: Starting install of '$($App.Name)' (StoreId: $($App.PackageId))" -Level Info

    # -----------------------------------------------------------------
    # Pre-flight validation
    # -----------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($App.PackageId)) {
        $App.InstallStatus = 'Failed'
        $App.InstallError  = 'PackageId (Store ID) is empty. Cannot install via Store.'
        Write-MigrationLog -Message "Store: $($App.InstallError)" -Level Error
        return $App
    }

    $wingetPath = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetPath) {
        # Cannot use winget at all -- fall back immediately
        Write-MigrationLog -Message "Store: winget is not available. Falling back to opening Store page." -Level Warning
        return Open-StoreFallback -App $App
    }

    # -----------------------------------------------------------------
    # Attempt winget install from msstore source
    # -----------------------------------------------------------------
    $arguments = @(
        'install'
        '--source'
        'msstore'
        '--id'
        $App.PackageId
        '--accept-package-agreements'
        '--accept-source-agreements'
        '--silent'
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        $processParams = @{
            FilePath               = $wingetPath.Source
            ArgumentList           = $arguments
            RedirectStandardOutput = $stdoutFile
            RedirectStandardError  = $stderrFile
            NoNewWindow            = $true
            PassThru               = $true
        }

        Write-MigrationLog -Message "Store: Executing: winget $($arguments -join ' ')" -Level Debug

        $process = Start-Process @processParams
        $exited  = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $exited) {
            try { $process.Kill() } catch { <# best effort #> }
            Write-MigrationLog -Message "Store: winget timed out after $TimeoutSeconds seconds. Falling back to Store page." -Level Warning
            return Open-StoreFallback -App $App
        }

        $exitCode = $process.ExitCode
        $stdout   = if (Test-Path $stdoutFile) { Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr   = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue } else { '' }

        Write-MigrationLog -Message "Store: Exit code $exitCode for '$($App.PackageId)'" -Level Debug

        # winget exit codes: 0 = success, -1978335189 = already installed
        $alreadyInstalledCode = -1978335189

        if ($exitCode -eq 0 -or $exitCode -eq $alreadyInstalledCode) {
            $App.InstallStatus = 'Success'
            $App.InstallError  = $null

            if ($exitCode -eq $alreadyInstalledCode) {
                Write-MigrationLog -Message "Store: '$($App.Name)' was already installed." -Level Info
            } else {
                Write-MigrationLog -Message "Store: '$($App.Name)' installed successfully via winget msstore." -Level Success
            }
            return $App
        }
        else {
            # winget msstore source failed -- fall back to opening the store page
            $combinedOutput = "$stdout $stderr".Trim()
            if ($combinedOutput.Length -gt 300) {
                $combinedOutput = $combinedOutput.Substring(0, 300) + '...'
            }
            Write-MigrationLog -Message "Store: winget msstore install failed (exit $exitCode). Output: $combinedOutput" -Level Warning
            Write-MigrationLog -Message "Store: Falling back to opening the Microsoft Store page." -Level Warning
            return Open-StoreFallback -App $App
        }
    }
    catch {
        Write-MigrationLog -Message "Store: Exception during winget msstore install: $($_.Exception.Message). Falling back to Store page." -Level Warning
        return Open-StoreFallback -App $App
    }
    finally {
        foreach ($f in @($stdoutFile, $stderrFile)) {
            if (Test-Path $f) {
                Remove-Item $f -Force -ErrorAction SilentlyContinue
            }
        }
    }
}


# -----------------------------------------------------------------
# Private helper: opens the Microsoft Store page as a fallback
# -----------------------------------------------------------------
function Open-StoreFallback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [MigrationApp]$App
    )

    try {
        $storeUrl = "ms-windows-store://pdp/?ProductId=$($App.PackageId)"
        Write-MigrationLog -Message "Store: Opening Store page: $storeUrl" -Level Info
        Start-Process $storeUrl -ErrorAction Stop

        # Also try the web URL as a secondary reference
        $webUrl = "https://apps.microsoft.com/detail/$($App.PackageId)"
        Write-MigrationLog -Message "Store: Web fallback URL: $webUrl" -Level Info

        $App.InstallStatus = 'Failed'
        $App.InstallError  = "Automatic install via winget msstore failed. The Microsoft Store page has been opened for manual installation."
        Write-MigrationLog -Message "Store: '$($App.Name)' requires manual installation from the Microsoft Store." -Level Warning
    }
    catch {
        $App.InstallStatus = 'Failed'
        $App.InstallError  = "Failed to install via winget msstore and could not open Store page: $($_.Exception.Message)"
        Write-MigrationLog -Message "Store: $($App.InstallError)" -Level Error
    }

    return $App
}
