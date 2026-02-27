<#
========================================================================================================
    Title:          Win11Migrator - Chocolatey Application Installer
    Filename:       Install-AppViaChocolatey.ps1
    Description:    Installs an application using the Chocolatey package manager.
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
    Installs an application using the Chocolatey package manager.

.DESCRIPTION
    Runs choco install for a given MigrationApp that has a PackageId set for
    the Chocolatey repository.  Captures exit code and output, handles timeouts,
    and updates InstallStatus / InstallError on the returned object.

.PARAMETER App
    A [MigrationApp] instance whose PackageId contains the Chocolatey package name.

.PARAMETER TimeoutSeconds
    Maximum seconds to wait for the installer to finish.
    Defaults to the SilentInstallTimeout value in AppSettings.json (600).

.OUTPUTS
    [MigrationApp] - the same object with InstallStatus and InstallError updated.
#>

function Install-AppViaChocolatey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [MigrationApp]$App,

        [int]$TimeoutSeconds = 600
    )

    Write-MigrationLog -Message "Chocolatey: Starting install of '$($App.Name)' (PackageId: $($App.PackageId))" -Level Info

    # -----------------------------------------------------------------
    # Pre-flight validation
    # -----------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($App.PackageId)) {
        $App.InstallStatus = 'Failed'
        $App.InstallError  = 'PackageId is empty. Cannot install via Chocolatey.'
        Write-MigrationLog -Message "Chocolatey: $($App.InstallError)" -Level Error
        return $App
    }

    $chocoPath = Get-Command choco -ErrorAction SilentlyContinue
    if (-not $chocoPath) {
        $App.InstallStatus = 'Failed'
        $App.InstallError  = 'Chocolatey is not available on this system. Run Install-Chocolatey first.'
        Write-MigrationLog -Message "Chocolatey: $($App.InstallError)" -Level Error
        return $App
    }

    # -----------------------------------------------------------------
    # Build arguments
    # -----------------------------------------------------------------
    $arguments = @(
        'install'
        $App.PackageId
        '-y'
        '--no-progress'
    )

    # -----------------------------------------------------------------
    # Execute with timeout via Start-Process
    # -----------------------------------------------------------------
    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        $processParams = @{
            FilePath               = $chocoPath.Source
            ArgumentList           = $arguments
            RedirectStandardOutput = $stdoutFile
            RedirectStandardError  = $stderrFile
            NoNewWindow            = $true
            PassThru               = $true
        }

        Write-MigrationLog -Message "Chocolatey: Executing: choco $($arguments -join ' ')" -Level Debug

        $process = Start-Process @processParams
        $exited  = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $exited) {
            try { $process.Kill() } catch { <# best effort #> }
            $App.InstallStatus = 'Failed'
            $App.InstallError  = "Installation timed out after $TimeoutSeconds seconds."
            Write-MigrationLog -Message "Chocolatey: $($App.InstallError) (PackageId: $($App.PackageId))" -Level Error
            return $App
        }

        $exitCode = $process.ExitCode
        $stdout   = if (Test-Path $stdoutFile) { Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr   = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue } else { '' }

        Write-MigrationLog -Message "Chocolatey: Exit code $exitCode for '$($App.PackageId)'" -Level Debug

        # -----------------------------------------------------------------
        # Evaluate result
        # choco exit codes: 0 = success, 1641/3010 = reboot needed (success),
        # other nonzero = failure
        # -----------------------------------------------------------------
        $successCodes = @(0, 1641, 3010)

        if ($exitCode -in $successCodes) {
            $App.InstallStatus = 'Success'
            $App.InstallError  = $null

            if ($exitCode -eq 1641 -or $exitCode -eq 3010) {
                Write-MigrationLog -Message "Chocolatey: '$($App.Name)' installed successfully (reboot may be required, exit code $exitCode)." -Level Warning
            } else {
                Write-MigrationLog -Message "Chocolatey: '$($App.Name)' installed successfully." -Level Success
            }
        } else {
            $App.InstallStatus = 'Failed'

            # Chocolatey writes most errors to stdout rather than stderr
            $errorDetail = if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                $stderr.Trim()
            } elseif (-not [string]::IsNullOrWhiteSpace($stdout)) {
                # Extract the most relevant portion (last 500 chars usually has the error)
                $trimmed = $stdout.Trim()
                if ($trimmed.Length -gt 500) {
                    '...' + $trimmed.Substring($trimmed.Length - 500)
                } else {
                    $trimmed
                }
            } else {
                "choco exited with code $exitCode"
            }

            if ($errorDetail.Length -gt 500) {
                $errorDetail = $errorDetail.Substring(0, 500) + '...(truncated)'
            }
            $App.InstallError = "Exit code $exitCode - $errorDetail"
            Write-MigrationLog -Message "Chocolatey: Failed to install '$($App.Name)': $($App.InstallError)" -Level Error
        }
    }
    catch {
        $App.InstallStatus = 'Failed'
        $App.InstallError  = "Exception during Chocolatey install: $($_.Exception.Message)"
        Write-MigrationLog -Message "Chocolatey: $($App.InstallError)" -Level Error
    }
    finally {
        foreach ($f in @($stdoutFile, $stderrFile)) {
            if (Test-Path $f) {
                Remove-Item $f -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return $App
}
