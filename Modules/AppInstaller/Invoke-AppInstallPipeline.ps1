<#
========================================================================================================
    Title:          Win11Migrator - Application Install Pipeline Orchestrator
    Filename:       Invoke-AppInstallPipeline.ps1
    Description:    Orchestrates sequential application installation across all install methods with failure isolation.
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
    Orchestrates the installation of all applications in a migration manifest.

.DESCRIPTION
    Accepts an array of MigrationApp objects, groups them by InstallMethod, and
    installs each app sequentially (to avoid MSI mutex conflicts and overlapping
    installer state).  For each app the appropriate Install-AppVia* function is
    called, wrapped in Invoke-WithRetry for transient-failure resilience.

    Progress is tracked and reported through:
      - Write-MigrationLog messages
      - A MigrationProgress object maintained internally
      - An optional -OnProgress callback scriptblock for GUI integration

    Individual app failures do NOT stop the pipeline.

.PARAMETER Apps
    Array of [MigrationApp] objects from the migration manifest.
    Only apps where Selected=$true and InstallStatus='Pending' are processed.

.PARAMETER Config
    Hashtable of configuration values from Initialize-Environment.
    Used to read SilentInstallTimeout, MaxRetryCount, RetryDelaySeconds,
    and the enabled-installer flags.

.PARAMETER OnProgress
    Optional scriptblock invoked after each app completes.  Receives a single
    [MigrationProgress] argument that the GUI can use to update its display.

.PARAMETER MaxRetries
    Maximum retry attempts per app for transient failures.
    Defaults to Config.MaxRetryCount (3).

.PARAMETER RetryDelaySeconds
    Seconds to wait between retries.
    Defaults to Config.RetryDelaySeconds (5).

.OUTPUTS
    [MigrationApp[]] - the input array with InstallStatus and InstallError
    updated for every processed app.
#>

function Invoke-AppInstallPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [MigrationApp[]]$Apps,

        [hashtable]$Config,

        [scriptblock]$OnProgress,

        [int]$MaxRetries,

        [int]$RetryDelaySeconds
    )

    # -----------------------------------------------------------------
    # Resolve configuration defaults
    # -----------------------------------------------------------------
    $timeout = 600
    if ($Config -and $Config.SilentInstallTimeout) {
        $timeout = [int]$Config.SilentInstallTimeout
    }

    if (-not $PSBoundParameters.ContainsKey('MaxRetries')) {
        $MaxRetries = if ($Config -and $Config.MaxRetryCount) { [int]$Config.MaxRetryCount } else { 3 }
    }

    if (-not $PSBoundParameters.ContainsKey('RetryDelaySeconds')) {
        $RetryDelaySeconds = if ($Config -and $Config.RetryDelaySeconds) { [int]$Config.RetryDelaySeconds } else { 5 }
    }

    # Build a lookup for which install methods are enabled
    $enabledMethods = @{
        Winget         = if ($Config) { [bool]$Config.EnableWinget }         else { $true }
        Chocolatey     = if ($Config) { [bool]$Config.EnableChocolatey }     else { $true }
        Ninite         = if ($Config) { [bool]$Config.EnableNinite }         else { $true }
        Store          = if ($Config) { [bool]$Config.EnableStoreApps }      else { $true }
        VendorDownload = if ($Config) { [bool]$Config.EnableVendorDownload } else { $true }
    }

    # -----------------------------------------------------------------
    # Filter apps to those eligible for installation
    # -----------------------------------------------------------------
    $pendingApps = @($Apps | Where-Object {
        $_.Selected -eq $true -and
        ($_.InstallStatus -eq 'Pending' -or [string]::IsNullOrWhiteSpace($_.InstallStatus))
    })

    $skippedApps = @($Apps | Where-Object {
        $_.Selected -ne $true -or
        ($_.InstallStatus -ne 'Pending' -and -not [string]::IsNullOrWhiteSpace($_.InstallStatus))
    })

    $totalCount     = $pendingApps.Count
    $completedCount = 0
    $failedCount    = 0

    Write-MigrationLog -Message "Pipeline: $totalCount app(s) queued for installation. $($skippedApps.Count) skipped (not selected or already processed)." -Level Info

    if ($totalCount -eq 0) {
        Write-MigrationLog -Message "Pipeline: No apps to install. Returning." -Level Info
        return $Apps
    }

    # -----------------------------------------------------------------
    # Ensure Chocolatey is available if any apps need it
    # -----------------------------------------------------------------
    $chocoApps = @($pendingApps | Where-Object { $_.InstallMethod -eq 'Chocolatey' })
    if ($chocoApps.Count -gt 0 -and $enabledMethods.Chocolatey) {
        $chocoAvailable = $false
        if ($Config -and $Config.ChocolateyAvailable) {
            $chocoAvailable = $true
        } else {
            $chocoAvailable = $null -ne (Get-Command choco -ErrorAction SilentlyContinue)
        }

        if (-not $chocoAvailable) {
            Write-MigrationLog -Message "Pipeline: Chocolatey is not installed. Attempting bootstrap." -Level Info
            $chocoInstalled = Install-Chocolatey
            if (-not $chocoInstalled) {
                Write-MigrationLog -Message "Pipeline: Chocolatey bootstrap failed. $($chocoApps.Count) Chocolatey app(s) will be marked as failed." -Level Error
                foreach ($ca in $chocoApps) {
                    $ca.InstallStatus = 'Failed'
                    $ca.InstallError  = 'Chocolatey is not available and bootstrap installation failed.'
                    $failedCount++
                    $completedCount++
                }
                # Remove these from the pending list so we don't try them again
                $pendingApps = @($pendingApps | Where-Object { $_.InstallMethod -ne 'Chocolatey' })
                $totalCount  = $pendingApps.Count + $chocoApps.Count
            }
        }
    }

    # -----------------------------------------------------------------
    # Define install method priority order
    # Installing sequentially to avoid MSI mutex and resource conflicts.
    # Winget and Store first (most reliable), then Chocolatey, Ninite,
    # and finally VendorDownload (least predictable).
    # -----------------------------------------------------------------
    $methodOrder = @('Winget', 'Store', 'Chocolatey', 'Ninite', 'VendorDownload', 'Manual')

    # Group pending apps by install method, preserving the order above
    $groupedApps = @{}
    foreach ($app in $pendingApps) {
        $method = if ($app.InstallMethod) { $app.InstallMethod } else { 'Manual' }
        if (-not $groupedApps.ContainsKey($method)) {
            $groupedApps[$method] = [System.Collections.ArrayList]::new()
        }
        [void]$groupedApps[$method].Add($app)
    }

    # -----------------------------------------------------------------
    # Process each install method group
    # -----------------------------------------------------------------
    foreach ($method in $methodOrder) {
        if (-not $groupedApps.ContainsKey($method)) { continue }

        $groupApps = $groupedApps[$method]
        Write-MigrationLog -Message "Pipeline: Processing $($groupApps.Count) app(s) via $method." -Level Info

        # Check if this method is enabled
        if ($enabledMethods.ContainsKey($method) -and -not $enabledMethods[$method]) {
            Write-MigrationLog -Message "Pipeline: $method is disabled in configuration. Skipping $($groupApps.Count) app(s)." -Level Warning
            foreach ($app in $groupApps) {
                $app.InstallStatus = 'Skipped'
                $app.InstallError  = "$method install method is disabled in configuration."
                $completedCount++
            }
            Invoke-ProgressCallback -OnProgress $OnProgress -Phase 'Installing' -CurrentItem '' -TotalItems $totalCount -CompletedItems $completedCount -FailedItems $failedCount -StatusMessage "$method disabled -- $($groupApps.Count) apps skipped."
            continue
        }

        foreach ($app in $groupApps) {
            Write-MigrationLog -Message "Pipeline: [$($completedCount + 1)/$totalCount] Installing '$($app.Name)' via $method..." -Level Info

            # Update progress before starting
            Invoke-ProgressCallback -OnProgress $OnProgress -Phase 'Installing' -CurrentItem $app.Name -TotalItems $totalCount -CompletedItems $completedCount -FailedItems $failedCount -StatusMessage "Installing '$($app.Name)' via $method..."

            try {
                # Wrap in Invoke-WithRetry for transient failures
                $updatedApp = Invoke-WithRetry -ScriptBlock {
                    switch ($method) {
                        'Winget' {
                            Install-AppViaWinget -App $app -TimeoutSeconds $timeout
                        }
                        'Chocolatey' {
                            Install-AppViaChocolatey -App $app -TimeoutSeconds $timeout
                        }
                        'Ninite' {
                            Install-AppViaNinite -App $app -TimeoutSeconds $timeout
                        }
                        'Store' {
                            Install-AppViaStore -App $app -TimeoutSeconds $timeout
                        }
                        'VendorDownload' {
                            Install-AppViaDownload -App $app -TimeoutSeconds $timeout -Config $Config
                        }
                        'Manual' {
                            $app.InstallStatus = 'Skipped'
                            $app.InstallError  = 'No automated install method available. Manual installation required.'
                            Write-MigrationLog -Message "Pipeline: '$($app.Name)' requires manual installation." -Level Warning
                            $app
                        }
                        default {
                            $app.InstallStatus = 'Failed'
                            $app.InstallError  = "Unknown install method: $method"
                            Write-MigrationLog -Message "Pipeline: Unknown install method '$method' for '$($app.Name)'." -Level Error
                            $app
                        }
                    }

                    # After the install function returns, check if it actually failed.
                    # If the status is 'Failed', throw so Invoke-WithRetry can retry.
                    if ($app.InstallStatus -eq 'Failed') {
                        throw "Install failed for '$($app.Name)': $($app.InstallError)"
                    }

                    return $app
                } -MaxRetries $MaxRetries -DelaySeconds $RetryDelaySeconds -OperationName "Install-$($app.Name)"
            }
            catch {
                # All retries exhausted -- the app object already has Failed status
                # set by the Install-AppVia* function.  Ensure it is set.
                if ($app.InstallStatus -ne 'Failed') {
                    $app.InstallStatus = 'Failed'
                    $app.InstallError  = "All retries exhausted: $($_.Exception.Message)"
                }
                Write-MigrationLog -Message "Pipeline: '$($app.Name)' installation failed after $MaxRetries retries: $($app.InstallError)" -Level Error
            }

            # Update counters
            $completedCount++
            if ($app.InstallStatus -eq 'Failed') {
                $failedCount++
            }

            # Log the result
            Write-MigrationLog -Message "Pipeline: '$($app.Name)' -- Status: $($app.InstallStatus)" -Level $(
                if ($app.InstallStatus -eq 'Success') { 'Success' }
                elseif ($app.InstallStatus -eq 'Skipped') { 'Warning' }
                else { 'Error' }
            )

            # Update progress after completion
            $statusMsg = "Completed '$($app.Name)' ($($app.InstallStatus)). $completedCount of $totalCount done, $failedCount failed."
            Invoke-ProgressCallback -OnProgress $OnProgress -Phase 'Installing' -CurrentItem $app.Name -TotalItems $totalCount -CompletedItems $completedCount -FailedItems $failedCount -StatusMessage $statusMsg
        }
    }

    # -----------------------------------------------------------------
    # Handle any apps with install methods not in our methodOrder list
    # -----------------------------------------------------------------
    $handledMethods = $methodOrder
    $unhandled = @($pendingApps | Where-Object {
        $_.InstallMethod -and
        $_.InstallMethod -notin $handledMethods -and
        ($_.InstallStatus -eq 'Pending' -or [string]::IsNullOrWhiteSpace($_.InstallStatus))
    })
    foreach ($app in $unhandled) {
        $app.InstallStatus = 'Skipped'
        $app.InstallError  = "Unrecognized install method: $($app.InstallMethod)"
        Write-MigrationLog -Message "Pipeline: '$($app.Name)' skipped -- unrecognized method '$($app.InstallMethod)'." -Level Warning
        $completedCount++
    }

    # -----------------------------------------------------------------
    # Final summary
    # -----------------------------------------------------------------
    $successCount = @($Apps | Where-Object { $_.InstallStatus -eq 'Success' }).Count
    $skipCount    = @($Apps | Where-Object { $_.InstallStatus -eq 'Skipped' }).Count
    $failCount    = @($Apps | Where-Object { $_.InstallStatus -eq 'Failed'  }).Count

    Write-MigrationLog -Message "Pipeline: Installation complete. Success: $successCount, Failed: $failCount, Skipped: $skipCount, Total: $($Apps.Count)" -Level Info

    # Final progress callback
    Invoke-ProgressCallback -OnProgress $OnProgress -Phase 'Installing' -CurrentItem '' -TotalItems $totalCount -CompletedItems $completedCount -FailedItems $failedCount -StatusMessage "Installation pipeline complete. Success: $successCount, Failed: $failCount, Skipped: $skipCount."

    return $Apps
}


# =================================================================
# Private helper: invoke the progress callback safely
# =================================================================
function Invoke-ProgressCallback {
    [CmdletBinding()]
    param(
        [scriptblock]$OnProgress,
        [string]$Phase,
        [string]$CurrentItem,
        [int]$TotalItems,
        [int]$CompletedItems,
        [int]$FailedItems,
        [string]$StatusMessage
    )

    if (-not $OnProgress) { return }

    try {
        $progress = [MigrationProgress]::new()
        $progress.Phase           = $Phase
        $progress.CurrentItem     = $CurrentItem
        $progress.TotalItems      = $TotalItems
        $progress.CompletedItems  = $CompletedItems
        $progress.FailedItems     = $FailedItems
        $progress.PercentComplete = if ($TotalItems -gt 0) { [math]::Round(($CompletedItems / $TotalItems) * 100, 1) } else { 0 }
        $progress.StatusMessage   = $StatusMessage

        & $OnProgress $progress
    }
    catch {
        Write-MigrationLog -Message "Pipeline: Progress callback error: $($_.Exception.Message)" -Level Warning
    }
}
