<#
========================================================================================================
    Title:          Win11Migrator - Remote Application Installer
    Filename:       Install-AppsRemotely.ps1
    Description:    Installs applications on a target machine via an established PSSession.
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
    Installs applications on a remote machine via PSSession.
.DESCRIPTION
    Takes an active PSSession and an array of MigrationApp objects. Iterates through
    each app and attempts installation using the appropriate method (Winget, Chocolatey,
    Store, or VendorDownload). Apps with a Manual install method are skipped and logged
    for inclusion in the manual install report.
.PARAMETER Session
    An established PSSession to the target machine.
.PARAMETER Apps
    Array of MigrationApp objects to install on the target.
.PARAMETER Progress
    Optional synchronized hashtable for reporting progress to the UI thread.
.OUTPUTS
    [hashtable] With Installed, Failed, Skipped counts and the updated Apps array.
.EXAMPLE
    $session = New-PSSession -ComputerName 'TARGET-PC' -Credential $cred
    $result = Install-AppsRemotely -Session $session -Apps $State.Apps
#>

function Install-AppsRemotely {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory)]
        [MigrationApp[]]$Apps,

        [Parameter()]
        [hashtable]$Progress
    )

    Write-MigrationLog -Message "Starting remote app installation for $($Apps.Count) app(s)" -Level Info

    $result = @{
        Installed = 0
        Failed    = 0
        Skipped   = 0
        Apps      = $Apps
    }

    # -------------------------------------------------------------------------
    # 1. Check winget availability on target
    # -------------------------------------------------------------------------
    $wingetAvailable = $false
    try {
        $wingetCheck = Invoke-Command -Session $Session -ScriptBlock {
            $wg = Get-Command winget -ErrorAction SilentlyContinue
            if ($wg) { return $true } else { return $false }
        } -ErrorAction Stop
        $wingetAvailable = $wingetCheck
        Write-MigrationLog -Message "Winget available on target: $wingetAvailable" -Level Info
    } catch {
        Write-MigrationLog -Message "Failed to check winget on target: $($_.Exception.Message)" -Level Warning
    }

    # -------------------------------------------------------------------------
    # 2. Check Chocolatey availability on target
    # -------------------------------------------------------------------------
    $chocoAvailable = $false
    try {
        $chocoCheck = Invoke-Command -Session $Session -ScriptBlock {
            $ch = Get-Command choco -ErrorAction SilentlyContinue
            if ($ch) { return $true } else { return $false }
        } -ErrorAction Stop
        $chocoAvailable = $chocoCheck
        Write-MigrationLog -Message "Chocolatey available on target: $chocoAvailable" -Level Info
    } catch {
        Write-MigrationLog -Message "Failed to check Chocolatey on target: $($_.Exception.Message)" -Level Warning
    }

    # -------------------------------------------------------------------------
    # 3. Install each app sequentially (avoid MSI mutex conflicts)
    # -------------------------------------------------------------------------
    $totalApps    = $Apps.Count
    $currentIndex = 0

    foreach ($app in $Apps) {
        $currentIndex++
        $pctBase = 65
        $pctRange = 25  # 65% to 90% of overall migration
        $pct = $pctBase + [math]::Floor(($currentIndex / [math]::Max($totalApps, 1)) * $pctRange)

        if ($Progress) {
            $Progress['Status'] = 'Installing Apps'
            $Progress['Percent'] = $pct
            $Progress['Detail'] = "[$currentIndex/$totalApps] $($app.Name)"
        }

        # Skip unselected apps
        if (-not $app.Selected) {
            $app.InstallStatus = 'Skipped'
            $result.Skipped++
            Write-MigrationLog -Message "Skipped (not selected): $($app.Name)" -Level Debug
            continue
        }

        Write-MigrationLog -Message "Installing [$currentIndex/$totalApps]: $($app.Name) via $($app.InstallMethod)" -Level Info

        switch ($app.InstallMethod) {
            'Winget' {
                if (-not $wingetAvailable) {
                    $app.InstallStatus = 'Failed'
                    $app.InstallError  = 'Winget is not available on the target machine.'
                    $result.Failed++
                    Write-MigrationLog -Message "Winget not available for '$($app.Name)'" -Level Warning
                    continue
                }

                if ([string]::IsNullOrWhiteSpace($app.PackageId)) {
                    $app.InstallStatus = 'Failed'
                    $app.InstallError  = 'PackageId is empty.'
                    $result.Failed++
                    Write-MigrationLog -Message "No PackageId for '$($app.Name)'" -Level Warning
                    continue
                }

                try {
                    $installResult = Invoke-Command -Session $Session -ScriptBlock {
                        param($packageId)
                        $output = winget install --id $packageId --accept-package-agreements --accept-source-agreements --silent 2>&1
                        return @{
                            ExitCode = $LASTEXITCODE
                            Output   = ($output | Out-String)
                        }
                    } -ArgumentList $app.PackageId -ErrorAction Stop

                    if ($installResult.ExitCode -eq 0) {
                        $app.InstallStatus = 'Installed'
                        $result.Installed++
                        Write-MigrationLog -Message "Winget install succeeded for '$($app.Name)'" -Level Info
                    } else {
                        $app.InstallStatus = 'Failed'
                        $app.InstallError  = "Winget exit code: $($installResult.ExitCode)"
                        $result.Failed++
                        Write-MigrationLog -Message "Winget install failed for '$($app.Name)': exit code $($installResult.ExitCode)" -Level Warning
                    }
                } catch {
                    $app.InstallStatus = 'Failed'
                    $app.InstallError  = $_.Exception.Message
                    $result.Failed++
                    Write-MigrationLog -Message "Winget install error for '$($app.Name)': $($_.Exception.Message)" -Level Error
                }
            }

            'Chocolatey' {
                if (-not $chocoAvailable) {
                    $app.InstallStatus = 'Failed'
                    $app.InstallError  = 'Chocolatey is not available on the target machine.'
                    $result.Failed++
                    Write-MigrationLog -Message "Chocolatey not available for '$($app.Name)'" -Level Warning
                    continue
                }

                if ([string]::IsNullOrWhiteSpace($app.PackageId)) {
                    $app.InstallStatus = 'Failed'
                    $app.InstallError  = 'PackageId is empty.'
                    $result.Failed++
                    Write-MigrationLog -Message "No PackageId for '$($app.Name)'" -Level Warning
                    continue
                }

                try {
                    $installResult = Invoke-Command -Session $Session -ScriptBlock {
                        param($packageId)
                        $output = choco install $packageId -y --no-progress 2>&1
                        return @{
                            ExitCode = $LASTEXITCODE
                            Output   = ($output | Out-String)
                        }
                    } -ArgumentList $app.PackageId -ErrorAction Stop

                    if ($installResult.ExitCode -eq 0) {
                        $app.InstallStatus = 'Installed'
                        $result.Installed++
                        Write-MigrationLog -Message "Chocolatey install succeeded for '$($app.Name)'" -Level Info
                    } else {
                        $app.InstallStatus = 'Failed'
                        $app.InstallError  = "Chocolatey exit code: $($installResult.ExitCode)"
                        $result.Failed++
                        Write-MigrationLog -Message "Chocolatey install failed for '$($app.Name)': exit code $($installResult.ExitCode)" -Level Warning
                    }
                } catch {
                    $app.InstallStatus = 'Failed'
                    $app.InstallError  = $_.Exception.Message
                    $result.Failed++
                    Write-MigrationLog -Message "Chocolatey install error for '$($app.Name)': $($_.Exception.Message)" -Level Error
                }
            }

            'Store' {
                # Attempt via winget with msstore source
                if ($wingetAvailable -and -not [string]::IsNullOrWhiteSpace($app.PackageId)) {
                    try {
                        $installResult = Invoke-Command -Session $Session -ScriptBlock {
                            param($packageId)
                            $output = winget install --id $packageId --source msstore --accept-package-agreements --accept-source-agreements --silent 2>&1
                            return @{
                                ExitCode = $LASTEXITCODE
                                Output   = ($output | Out-String)
                            }
                        } -ArgumentList $app.PackageId -ErrorAction Stop

                        if ($installResult.ExitCode -eq 0) {
                            $app.InstallStatus = 'Installed'
                            $result.Installed++
                            Write-MigrationLog -Message "Store app '$($app.Name)' installed via winget" -Level Info
                        } else {
                            $app.InstallStatus = 'Manual'
                            $app.InstallError  = 'Store app requires manual installation from Microsoft Store.'
                            $result.Skipped++
                            Write-MigrationLog -Message "Store app '$($app.Name)' requires manual install" -Level Warning
                        }
                    } catch {
                        $app.InstallStatus = 'Manual'
                        $app.InstallError  = "Store install failed: $($_.Exception.Message)"
                        $result.Skipped++
                        Write-MigrationLog -Message "Store install error for '$($app.Name)': $($_.Exception.Message)" -Level Warning
                    }
                } else {
                    $app.InstallStatus = 'Manual'
                    $app.InstallError  = 'Store app requires manual installation.'
                    $result.Skipped++
                    Write-MigrationLog -Message "Store app '$($app.Name)' marked for manual install (no winget)" -Level Info
                }
            }

            'VendorDownload' {
                if ([string]::IsNullOrWhiteSpace($app.DownloadUrl)) {
                    $app.InstallStatus = 'Manual'
                    $app.InstallError  = 'No download URL available.'
                    $result.Skipped++
                    Write-MigrationLog -Message "No download URL for '$($app.Name)'" -Level Warning
                    continue
                }

                try {
                    $installResult = Invoke-Command -Session $Session -ScriptBlock {
                        param($url, $appName)
                        $tempDir    = Join-Path $env:TEMP 'Win11Migrator_Downloads'
                        if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }
                        $fileName   = Split-Path $url -Leaf
                        if (-not $fileName -or $fileName.Length -lt 3) { $fileName = "$appName`_setup.exe" }
                        $targetFile = Join-Path $tempDir $fileName

                        # Download
                        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
                        $wc = New-Object System.Net.WebClient
                        $wc.DownloadFile($url, $targetFile)

                        # Run installer silently
                        $ext = [System.IO.Path]::GetExtension($targetFile).ToLower()
                        $silentArgs = switch ($ext) {
                            '.msi' { "/i `"$targetFile`" /qn /norestart" }
                            '.exe' { '/S /silent /VERYSILENT /norestart' }
                            default { '' }
                        }

                        if ($ext -eq '.msi') {
                            $proc = Start-Process 'msiexec.exe' -ArgumentList $silentArgs -Wait -PassThru -ErrorAction Stop
                        } else {
                            $proc = Start-Process $targetFile -ArgumentList $silentArgs -Wait -PassThru -ErrorAction Stop
                        }

                        # Clean up
                        Remove-Item $targetFile -Force -ErrorAction SilentlyContinue

                        return @{ ExitCode = $proc.ExitCode }
                    } -ArgumentList $app.DownloadUrl, $app.Name -ErrorAction Stop

                    if ($installResult.ExitCode -eq 0 -or $installResult.ExitCode -eq 3010) {
                        $app.InstallStatus = 'Installed'
                        $result.Installed++
                        Write-MigrationLog -Message "Vendor download install succeeded for '$($app.Name)'" -Level Info
                    } else {
                        $app.InstallStatus = 'Failed'
                        $app.InstallError  = "Installer exit code: $($installResult.ExitCode)"
                        $result.Failed++
                        Write-MigrationLog -Message "Vendor download install failed for '$($app.Name)': exit code $($installResult.ExitCode)" -Level Warning
                    }
                } catch {
                    $app.InstallStatus = 'Failed'
                    $app.InstallError  = $_.Exception.Message
                    $result.Failed++
                    Write-MigrationLog -Message "Vendor download error for '$($app.Name)': $($_.Exception.Message)" -Level Error
                }
            }

            'Manual' {
                $app.InstallStatus = 'Manual'
                $app.InstallError  = 'Requires manual installation.'
                $result.Skipped++
                Write-MigrationLog -Message "Manual install required for '$($app.Name)'" -Level Info
            }

            default {
                $app.InstallStatus = 'Skipped'
                $app.InstallError  = "Unknown install method: $($app.InstallMethod)"
                $result.Skipped++
                Write-MigrationLog -Message "Unknown install method for '$($app.Name)': $($app.InstallMethod)" -Level Warning
            }
        }
    }

    Write-MigrationLog -Message "Remote app installation complete: $($result.Installed) installed, $($result.Failed) failed, $($result.Skipped) skipped" -Level Info

    return $result
}
