<#
========================================================================================================
    Title:          Win11Migrator - Ninite Application Installer
    Filename:       Install-AppViaNinite.ps1
    Description:    Installs an application using the Ninite silent installer service.
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
    Installs an application using the Ninite web installer.

.DESCRIPTION
    Ninite provides a single-click, silent installer for popular free applications.
    This function constructs the Ninite download URL for the requested app, downloads
    the custom installer EXE, and runs it silently.

    IMPORTANT: The free version of Ninite has limitations:
      - No CLI/scripting support beyond launching the downloaded installer.
      - The installer auto-selects apps based on the URL path -- only one app at a time
        is requested here to keep status tracking per-app.
      - Ninite Pro (paid) offers proper CLI/logging.  This function targets the free tier.

.PARAMETER App
    A [MigrationApp] instance whose PackageId contains the Ninite-compatible slug
    (e.g. "chrome", "vlc", "7zip").  See Config/NiniteAppList.json for the mapping.

.PARAMETER TimeoutSeconds
    Maximum seconds to wait for the Ninite installer to finish.
    Defaults to the SilentInstallTimeout value in AppSettings.json (600).

.OUTPUTS
    [MigrationApp] - the same object with InstallStatus and InstallError updated.
#>

function Install-AppViaNinite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [MigrationApp]$App,

        [int]$TimeoutSeconds = 600
    )

    Write-MigrationLog -Message "Ninite: Starting install of '$($App.Name)' (NiniteSlug: $($App.PackageId))" -Level Info

    # -----------------------------------------------------------------
    # Advisory: Ninite free-tier limitations
    # -----------------------------------------------------------------
    Write-MigrationLog -Message "Ninite: NOTE - Using the free Ninite installer. It always installs the latest version and does not provide granular exit codes. For enterprise use consider Ninite Pro." -Level Warning

    # -----------------------------------------------------------------
    # Pre-flight validation
    # -----------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($App.PackageId)) {
        $App.InstallStatus = 'Failed'
        $App.InstallError  = 'PackageId (Ninite slug) is empty. Cannot install via Ninite.'
        Write-MigrationLog -Message "Ninite: $($App.InstallError)" -Level Error
        return $App
    }

    # Sanitize the slug -- only allow alphanumeric, hyphens, and dots
    $slug = $App.PackageId.Trim().ToLower()
    if ($slug -notmatch '^[a-z0-9\.\-]+$') {
        $App.InstallStatus = 'Failed'
        $App.InstallError  = "Invalid Ninite slug '$slug'. Expected alphanumeric characters, dots, or hyphens only."
        Write-MigrationLog -Message "Ninite: $($App.InstallError)" -Level Error
        return $App
    }

    # -----------------------------------------------------------------
    # Download the Ninite installer
    # -----------------------------------------------------------------
    $niniteUrl    = "https://ninite.com/$slug/ninite.exe"
    $tempDir      = Join-Path ([System.IO.Path]::GetTempPath()) "Win11Migrator_Ninite"
    $installerExe = Join-Path $tempDir "Ninite_${slug}.exe"

    try {
        if (-not (Test-Path $tempDir)) {
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        }

        Write-MigrationLog -Message "Ninite: Downloading installer from $niniteUrl" -Level Info

        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($niniteUrl, $installerExe)

        if (-not (Test-Path $installerExe)) {
            $App.InstallStatus = 'Failed'
            $App.InstallError  = "Download failed: installer file not found at '$installerExe'."
            Write-MigrationLog -Message "Ninite: $($App.InstallError)" -Level Error
            return $App
        }

        $fileSize = (Get-Item $installerExe).Length
        if ($fileSize -lt 10000) {
            # Ninite returns a very small HTML page if the slug is invalid
            $App.InstallStatus = 'Failed'
            $App.InstallError  = "Downloaded file is unexpectedly small ($fileSize bytes). The Ninite slug '$slug' may be invalid."
            Write-MigrationLog -Message "Ninite: $($App.InstallError)" -Level Error
            return $App
        }

        Write-MigrationLog -Message "Ninite: Installer downloaded ($fileSize bytes)." -Level Debug
    }
    catch {
        $App.InstallStatus = 'Failed'
        $App.InstallError  = "Failed to download Ninite installer: $($_.Exception.Message)"
        Write-MigrationLog -Message "Ninite: $($App.InstallError)" -Level Error
        return $App
    }

    # -----------------------------------------------------------------
    # Execute the installer silently
    # -----------------------------------------------------------------
    try {
        $processParams = @{
            FilePath     = $installerExe
            NoNewWindow  = $true
            PassThru     = $true
        }

        Write-MigrationLog -Message "Ninite: Launching installer: $installerExe" -Level Debug

        $process = Start-Process @processParams
        $exited  = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $exited) {
            try { $process.Kill() } catch { <# best effort #> }
            $App.InstallStatus = 'Failed'
            $App.InstallError  = "Ninite installer timed out after $TimeoutSeconds seconds."
            Write-MigrationLog -Message "Ninite: $($App.InstallError)" -Level Error
            return $App
        }

        $exitCode = $process.ExitCode

        Write-MigrationLog -Message "Ninite: Installer exited with code $exitCode for '$($App.Name)'." -Level Debug

        # Ninite free returns 0 on success.  Non-zero indicates an issue,
        # but detailed error info is only available in Ninite Pro audit logs.
        if ($exitCode -eq 0) {
            $App.InstallStatus = 'Success'
            $App.InstallError  = $null
            Write-MigrationLog -Message "Ninite: '$($App.Name)' installed successfully." -Level Success
        } else {
            $App.InstallStatus = 'Failed'
            $App.InstallError  = "Ninite installer exited with code $exitCode. Detailed error info requires Ninite Pro."
            Write-MigrationLog -Message "Ninite: $($App.InstallError)" -Level Error
        }
    }
    catch {
        $App.InstallStatus = 'Failed'
        $App.InstallError  = "Exception running Ninite installer: $($_.Exception.Message)"
        Write-MigrationLog -Message "Ninite: $($App.InstallError)" -Level Error
    }
    finally {
        # -----------------------------------------------------------------
        # Cleanup downloaded installer
        # -----------------------------------------------------------------
        if (Test-Path $installerExe) {
            Remove-Item $installerExe -Force -ErrorAction SilentlyContinue
            Write-MigrationLog -Message "Ninite: Cleaned up installer file." -Level Debug
        }
    }

    return $App
}
