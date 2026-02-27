<#
========================================================================================================
    Title:          Win11Migrator - Vendor Download Installer
    Filename:       Install-AppViaDownload.ps1
    Description:    Downloads and runs a vendor-provided installer for a given application.
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
    Installs an application by downloading its installer from a vendor URL.

.DESCRIPTION
    Downloads the installer to a temporary directory, detects the file type
    (.msi or .exe), and runs the appropriate silent installation command.
    For MSI: uses msiexec /i ... /qn /norestart.
    For EXE: tries a sequence of common silent switches until one succeeds,
    or uses vendor-specific silent arguments from VendorDownloadUrls.json.
    Handles timeouts and cleans up the downloaded installer afterward.

.PARAMETER App
    A [MigrationApp] instance with DownloadUrl set.  If VendorDownloadUrls.json
    contains a matching entry with SilentArgs, those arguments are preferred.

.PARAMETER TimeoutSeconds
    Maximum seconds to wait for the installer to finish.
    Defaults to the SilentInstallTimeout value in AppSettings.json (600).

.PARAMETER Config
    Optional hashtable of configuration values (from Initialize-Environment).
    Used to resolve the path to VendorDownloadUrls.json.

.OUTPUTS
    [MigrationApp] - the same object with InstallStatus and InstallError updated.
#>

function Install-AppViaDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [MigrationApp]$App,

        [int]$TimeoutSeconds = 600,

        [hashtable]$Config
    )

    Write-MigrationLog -Message "Download: Starting install of '$($App.Name)' (URL: $($App.DownloadUrl))" -Level Info

    # -----------------------------------------------------------------
    # Pre-flight validation
    # -----------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($App.DownloadUrl)) {
        $App.InstallStatus = 'Failed'
        $App.InstallError  = 'DownloadUrl is empty. Cannot install via direct download.'
        Write-MigrationLog -Message "Download: $($App.InstallError)" -Level Error
        return $App
    }

    # -----------------------------------------------------------------
    # Load vendor download metadata if available
    # -----------------------------------------------------------------
    $vendorInfo = $null
    $vendorConfigPath = $null
    if ($Config -and $Config.RootPath) {
        $vendorConfigPath = Join-Path $Config.RootPath 'Config\VendorDownloadUrls.json'
    }
    if (-not $vendorConfigPath) {
        # Try to derive from script location
        $scriptRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $vendorConfigPath = Join-Path $scriptRoot 'Config\VendorDownloadUrls.json'
    }

    if ($vendorConfigPath -and (Test-Path $vendorConfigPath)) {
        try {
            $vendorData = Get-Content $vendorConfigPath -Raw | ConvertFrom-Json
            $normalizedName = $App.NormalizedName
            if (-not $normalizedName) { $normalizedName = $App.Name }
            $lookupKey = $normalizedName.ToLower().Trim()

            if ($vendorData.$lookupKey) {
                $vendorInfo = $vendorData.$lookupKey
                Write-MigrationLog -Message "Download: Found vendor metadata for '$lookupKey'." -Level Debug
            }
        }
        catch {
            Write-MigrationLog -Message "Download: Could not load VendorDownloadUrls.json: $($_.Exception.Message)" -Level Warning
        }
    }

    # If the vendor entry has InstallerType = "manual", flag it and return
    if ($vendorInfo -and $vendorInfo.InstallerType -eq 'manual') {
        $notes = if ($vendorInfo.Notes) { $vendorInfo.Notes } else { 'This application requires manual installation.' }
        $App.InstallStatus = 'Failed'
        $App.InstallError  = "Manual installation required: $notes"
        Write-MigrationLog -Message "Download: '$($App.Name)' - $($App.InstallError)" -Level Warning
        return $App
    }

    # -----------------------------------------------------------------
    # Download the installer
    # -----------------------------------------------------------------
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "Win11Migrator_Download"
    if (-not (Test-Path $tempDir)) {
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    }

    $downloadUrl = $App.DownloadUrl
    $installerPath = $null

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

        # Determine the file name from the URL or content-disposition
        $uri = [System.Uri]$downloadUrl
        $fileName = [System.IO.Path]::GetFileName($uri.LocalPath)
        if ([string]::IsNullOrWhiteSpace($fileName) -or $fileName -notmatch '\.(msi|exe)$') {
            # Fall back to a generic name based on vendor info or app name
            $extension = '.exe'
            if ($vendorInfo -and $vendorInfo.InstallerType -eq 'msi') {
                $extension = '.msi'
            }
            $safeName = ($App.Name -replace '[^\w\-]', '_')
            $fileName = "${safeName}_installer${extension}"
        }

        $installerPath = Join-Path $tempDir $fileName
        Write-MigrationLog -Message "Download: Downloading from '$downloadUrl' to '$installerPath'" -Level Info

        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($downloadUrl, $installerPath)

        if (-not (Test-Path $installerPath)) {
            $App.InstallStatus = 'Failed'
            $App.InstallError  = "Download completed but file not found at '$installerPath'."
            Write-MigrationLog -Message "Download: $($App.InstallError)" -Level Error
            return $App
        }

        $fileSize = (Get-Item $installerPath).Length
        Write-MigrationLog -Message "Download: File downloaded ($fileSize bytes)." -Level Debug

        if ($fileSize -lt 1024) {
            $App.InstallStatus = 'Failed'
            $App.InstallError  = "Downloaded file is suspiciously small ($fileSize bytes). The URL may be invalid or require authentication."
            Write-MigrationLog -Message "Download: $($App.InstallError)" -Level Error
            return $App
        }
    }
    catch {
        $App.InstallStatus = 'Failed'
        $App.InstallError  = "Failed to download installer: $($_.Exception.Message)"
        Write-MigrationLog -Message "Download: $($App.InstallError)" -Level Error
        return $App
    }

    # -----------------------------------------------------------------
    # Detect installer type and run silent install
    # -----------------------------------------------------------------
    try {
        $extension = [System.IO.Path]::GetExtension($installerPath).ToLower()

        # Override extension based on vendor metadata
        if ($vendorInfo -and $vendorInfo.InstallerType) {
            if ($vendorInfo.InstallerType -eq 'msi') {
                $extension = '.msi'
            } elseif ($vendorInfo.InstallerType -eq 'exe') {
                $extension = '.exe'
            }
        }

        if ($extension -eq '.msi') {
            $result = Install-Msi -MsiPath $installerPath -TimeoutSeconds $TimeoutSeconds
        }
        elseif ($extension -eq '.exe') {
            $silentArgs = $null
            if ($vendorInfo -and -not [string]::IsNullOrWhiteSpace($vendorInfo.SilentArgs)) {
                $silentArgs = $vendorInfo.SilentArgs
            }
            $result = Install-Exe -ExePath $installerPath -SilentArgs $silentArgs -TimeoutSeconds $TimeoutSeconds
        }
        else {
            $App.InstallStatus = 'Failed'
            $App.InstallError  = "Unsupported installer type '$extension'. Only .msi and .exe are supported."
            Write-MigrationLog -Message "Download: $($App.InstallError)" -Level Error
            return $App
        }

        $App.InstallStatus = $result.Status
        $App.InstallError  = $result.Error

        if ($result.Status -eq 'Success') {
            Write-MigrationLog -Message "Download: '$($App.Name)' installed successfully." -Level Success
        } else {
            Write-MigrationLog -Message "Download: '$($App.Name)' installation failed: $($result.Error)" -Level Error
        }
    }
    catch {
        $App.InstallStatus = 'Failed'
        $App.InstallError  = "Exception during installation: $($_.Exception.Message)"
        Write-MigrationLog -Message "Download: $($App.InstallError)" -Level Error
    }
    finally {
        # -----------------------------------------------------------------
        # Cleanup downloaded file
        # -----------------------------------------------------------------
        if ($installerPath -and (Test-Path $installerPath)) {
            Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
            Write-MigrationLog -Message "Download: Cleaned up installer file '$installerPath'." -Level Debug
        }
    }

    return $App
}


# =================================================================
# Private helper: Install an MSI package
# =================================================================
function Install-Msi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MsiPath,

        [int]$TimeoutSeconds = 600
    )

    $logFile   = [System.IO.Path]::GetTempFileName()
    $arguments = "/i `"$MsiPath`" /qn /norestart /l*v `"$logFile`""

    Write-MigrationLog -Message "Download: Running msiexec $arguments" -Level Debug

    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -NoNewWindow -PassThru
    $exited  = $process.WaitForExit($TimeoutSeconds * 1000)

    if (-not $exited) {
        try { $process.Kill() } catch { <# best effort #> }
        # Also kill any child msiexec processes
        try { Get-Process msiexec -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -gt (Get-Date).AddSeconds(-$TimeoutSeconds) } | Stop-Process -Force -ErrorAction SilentlyContinue } catch { <# ignore #> }
        if (Test-Path $logFile) { Remove-Item $logFile -Force -ErrorAction SilentlyContinue }
        return @{ Status = 'Failed'; Error = "MSI installation timed out after $TimeoutSeconds seconds." }
    }

    $exitCode = $process.ExitCode

    # Read MSI log for error details
    $logContent = ''
    if (Test-Path $logFile) {
        $logContent = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
        Remove-Item $logFile -Force -ErrorAction SilentlyContinue
    }

    # MSI success codes: 0 = success, 3010 = reboot required
    if ($exitCode -eq 0 -or $exitCode -eq 3010) {
        if ($exitCode -eq 3010) {
            Write-MigrationLog -Message "Download: MSI installed successfully (reboot required)." -Level Warning
        }
        return @{ Status = 'Success'; Error = $null }
    }
    else {
        $errorMsg = "msiexec exited with code $exitCode."
        # Try to extract a meaningful error from the log
        if ($logContent -and $logContent.Length -gt 0) {
            $errorLines = $logContent -split "`n" | Where-Object { $_ -match 'error|failed|cannot' } | Select-Object -Last 3
            if ($errorLines) {
                $detail = ($errorLines -join ' ').Trim()
                if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) + '...' }
                $errorMsg += " $detail"
            }
        }
        return @{ Status = 'Failed'; Error = $errorMsg }
    }
}


# =================================================================
# Private helper: Install an EXE package
# =================================================================
function Install-Exe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExePath,

        [string]$SilentArgs,

        [int]$TimeoutSeconds = 600
    )

    # If vendor-specific silent args are provided, use those directly
    if (-not [string]::IsNullOrWhiteSpace($SilentArgs)) {
        Write-MigrationLog -Message "Download: Using vendor-specific silent args: $SilentArgs" -Level Debug
        return Invoke-ExeInstaller -ExePath $ExePath -Arguments $SilentArgs -TimeoutSeconds $TimeoutSeconds
    }

    # Otherwise, try common silent switch patterns in order of likelihood
    $silentSwitchSets = @(
        '/S'
        '/silent'
        '/VERYSILENT /NORESTART'
        '/quiet /norestart'
        '-s'
        '--silent'
    )

    $lastResult = $null

    foreach ($switches in $silentSwitchSets) {
        Write-MigrationLog -Message "Download: Trying silent switches: $switches" -Level Debug

        $result = Invoke-ExeInstaller -ExePath $ExePath -Arguments $switches -TimeoutSeconds $TimeoutSeconds

        if ($result.Status -eq 'Success') {
            return $result
        }

        $lastResult = $result

        # If the process timed out, do not try additional switch sets
        if ($result.Error -and $result.Error -match 'timed out') {
            Write-MigrationLog -Message "Download: Installer timed out -- not trying additional switch sets." -Level Warning
            return $result
        }

        # Exit code 1 often means "wrong arguments" -- try the next set.
        # Any other non-zero code might indicate a real install error, not just
        # bad switches.  We try at most a couple more sets before giving up.
    }

    # If none of the switch sets worked, return the last failure
    if ($lastResult) {
        $lastResult.Error = "All common silent switches failed. Last attempt: $($lastResult.Error)"
    } else {
        $lastResult = @{ Status = 'Failed'; Error = 'No silent switch sets available.' }
    }
    return $lastResult
}


# =================================================================
# Private helper: Run an EXE with specific arguments
# =================================================================
function Invoke-ExeInstaller {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExePath,

        [string]$Arguments,

        [int]$TimeoutSeconds = 600
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        $processParams = @{
            FilePath               = $ExePath
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $stdoutFile
            RedirectStandardError  = $stderrFile
        }
        if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
            $processParams['ArgumentList'] = $Arguments
        }

        $process = Start-Process @processParams
        $exited  = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $exited) {
            try { $process.Kill() } catch { <# best effort #> }
            return @{ Status = 'Failed'; Error = "EXE installer timed out after $TimeoutSeconds seconds (args: $Arguments)." }
        }

        $exitCode = $process.ExitCode

        # 0 = success, 3010/1641 = reboot needed (treat as success)
        if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq 1641) {
            return @{ Status = 'Success'; Error = $null }
        }
        else {
            $stderr = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue } else { '' }
            $detail = if (-not [string]::IsNullOrWhiteSpace($stderr)) { $stderr.Trim() } else { '' }
            if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) + '...' }
            $errorMsg = "Exit code $exitCode (args: $Arguments)"
            if ($detail) { $errorMsg += " - $detail" }
            return @{ Status = 'Failed'; Error = $errorMsg }
        }
    }
    catch {
        return @{ Status = 'Failed'; Error = "Exception: $($_.Exception.Message)" }
    }
    finally {
        foreach ($f in @($stdoutFile, $stderrFile)) {
            if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        }
    }
}
