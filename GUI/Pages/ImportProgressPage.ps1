<#
========================================================================================================
    Title:          Win11Migrator - Import Progress Page
    Filename:       ImportProgressPage.ps1
    Description:    Displays real-time progress during the migration package import and restoration process.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-ImportProgressPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $ui = @{
        Title      = $Page.FindName('txtImportTitle')
        Phase      = $Page.FindName('txtImportPhase')
        Progress   = $Page.FindName('progressImport')
        Percent    = $Page.FindName('txtImportPercent')
        Current    = $Page.FindName('txtCurrentImportItem')
        Success    = $Page.FindName('txtSuccessCount')
        Failed     = $Page.FindName('txtFailedCount')
        Remaining  = $Page.FindName('txtRemainingCount')
        Log        = $Page.FindName('txtImportLog')
    }

    $State.BtnNext.IsEnabled = $false
    $State.BtnBack.IsEnabled = $false

    $totalItems = $State.Apps.Count + $State.UserData.Count + $State.BrowserProfiles.Count + $State.SystemSettings.Count
    $ui.Remaining.Text = "$totalItems"

    # Synchronized hashtable for progress reporting from background thread
    $importProgress = [hashtable]::Synchronized(@{
        Phase     = 'Preparing...'
        Percent   = 0
        Item      = ''
        Log       = [System.Collections.ArrayList]::new()
        Done      = $false
        Succeeded = 0
        Failed    = 0
        Remaining = $totalItems
    })

    # Wrap the job reference in a hashtable so closures capture it properly
    $ctx = @{ Job = $null; Progress = $importProgress; LastLogIdx = 0 }

    # Start import in a background runspace
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('State', $State)
    $runspace.SessionStateProxy.SetVariable('prog', $importProgress)
    $runspace.SessionStateProxy.SetVariable('MigratorRoot', $State.MigratorRoot)
    $runspace.SessionStateProxy.SetVariable('Config', $State.Config)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace
    $ps.AddScript({
        # --- Load required modules into runspace ---
        . (Join-Path $MigratorRoot "Core\Initialize-Environment.ps1")
        . (Join-Path $MigratorRoot "Core\Write-MigrationLog.ps1")
        . (Join-Path $MigratorRoot "Core\ConvertTo-MigrationManifest.ps1")
        . (Join-Path $MigratorRoot "Core\Invoke-WithRetry.ps1")
        Get-ChildItem (Join-Path $MigratorRoot "Modules\AppDiscovery\*.ps1") | ForEach-Object { . $_.FullName }
        Get-ChildItem (Join-Path $MigratorRoot "Modules\AppInstaller\*.ps1") | ForEach-Object { . $_.FullName }
        Get-ChildItem (Join-Path $MigratorRoot "Modules\UserData\*.ps1") | ForEach-Object { . $_.FullName }
        Get-ChildItem (Join-Path $MigratorRoot "Modules\BrowserProfiles\*.ps1") | ForEach-Object { . $_.FullName }
        Get-ChildItem (Join-Path $MigratorRoot "Modules\SystemSettings\*.ps1") | ForEach-Object { . $_.FullName }
        Get-ChildItem (Join-Path $MigratorRoot "Modules\AppProfiles\*.ps1") | ForEach-Object { . $_.FullName }
        Get-ChildItem (Join-Path $MigratorRoot "Reports\*.ps1") | ForEach-Object { . $_.FullName }

        # Set script-scope variables that modules depend on
        $script:MigratorRoot = $MigratorRoot
        $script:Config = $Config

        $succeeded = 0
        $failed = 0
        $errors = @()

        # Phase 0: Create rollback snapshot
        $prog.Phase = 'Creating rollback snapshot...'
        $prog.Percent = 1
        $null = $prog.Log.Add('[Phase 0] Creating rollback snapshot...')
        try {
            . (Join-Path $MigratorRoot "Core\New-RollbackSnapshot.ps1")
            $snapshotPath = Join-Path $State.PackagePath "RollbackSnapshot"
            $userPaths = @($env:USERPROFILE)
            $regPaths = @(
                'HKCU:\Control Panel\Accessibility',
                'HKCU:\Control Panel\International',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced',
                'HKCU:\Control Panel\Keyboard',
                'HKCU:\Control Panel\Mouse'
            )
            $snapResult = New-RollbackSnapshot -SnapshotPath $snapshotPath -UserDataPaths $userPaths -RegistryPaths $regPaths
            if ($snapResult.Success) {
                $null = $prog.Log.Add("  Rollback snapshot created")
                $State['RollbackSnapshotPath'] = $snapshotPath
            }
        } catch {
            $null = $prog.Log.Add("  [WARN] Rollback snapshot: $($_.Exception.Message)")
        }

        # Phase 0.5: USMT LoadState (if USMT store present in package)
        $usmtStoreDir = Join-Path $State.PackagePath "USMTStore"
        if (Test-Path $usmtStoreDir) {
            $prog.Phase = 'Running USMT LoadState...'
            $prog.Percent = 1
            $null = $prog.Log.Add('[Phase 0.5] Running USMT LoadState...')
            try {
                . (Join-Path $MigratorRoot "Modules\USMT\Test-USMTAvailability.ps1")
                . (Join-Path $MigratorRoot "Modules\USMT\Invoke-USMTLoadState.ps1")
                $usmt = Test-USMTAvailability
                if ($usmt.Available) {
                    $usmtXmls = @($usmt.MigAppXml, $usmt.MigDocsXml, $usmt.MigUserXml) | Where-Object { $_ -and (Test-Path $_) }
                    $usmtLog = Join-Path $State.PackagePath "usmt_loadstate.log"
                    $usmtResult = Invoke-USMTLoadState -LoadStatePath $usmt.LoadStatePath -StorePath $usmtStoreDir -MigrationXmls $usmtXmls -LogPath $usmtLog
                    if ($usmtResult.Success) {
                        $null = $prog.Log.Add("  USMT LoadState completed successfully")
                    } else {
                        $null = $prog.Log.Add("  USMT LoadState failed: $($usmtResult.ErrorMessage)")
                    }
                } else {
                    $null = $prog.Log.Add("  USMT not available on target - skipping USMT restore")
                }
            } catch {
                $null = $prog.Log.Add("  [WARN] USMT LoadState: $($_.Exception.Message)")
            }
        }

        # Detect cross-OS migration
        try {
            . (Join-Path $MigratorRoot "Core\Get-OSMigrationContext.ps1")
            $targetOSContext = Get-OSMigrationContext
            $State['TargetOSContext'] = $targetOSContext
            if ($State.Manifest -and $State.Manifest.SourceOSContext) {
                $sourceCtx = $State.Manifest.SourceOSContext
                $isCrossOS = ($sourceCtx.IsWindows10 -and $targetOSContext.IsWindows11) -or ($sourceCtx.IsWindows11 -and $targetOSContext.IsWindows10)
                if ($isCrossOS) {
                    $null = $prog.Log.Add("  Cross-OS migration detected: source=$($sourceCtx.DisplayVersion) target=$($targetOSContext.DisplayVersion)")
                    $State['IsCrossOSMigration'] = $true
                }
            }
        } catch {
            $null = $prog.Log.Add("  [WARN] OS detection: $($_.Exception.Message)")
        }

        # Phase 1: Install applications (0-50%)
        $prog.Phase = 'Installing applications...'
        $prog.Percent = 2
        $null = $prog.Log.Add('[Phase 1/6] Installing applications...')
        try {
            $appsToInstall = $State.Apps | Where-Object { $_.Selected -and $_.InstallMethod -ne 'Manual' }
            if ($appsToInstall) {
                $appCount = @($appsToInstall).Count
                $null = $prog.Log.Add("  Installing $appCount applications via auto-install...")
                $State.Apps = Invoke-AppInstallPipeline -Apps $appsToInstall -Config $State.Config
                $succeeded += @($State.Apps | Where-Object { $_.InstallStatus -eq 'Success' }).Count
                $failed += @($State.Apps | Where-Object { $_.InstallStatus -eq 'Failed' }).Count
                $null = $prog.Log.Add("  App install complete: $succeeded succeeded, $failed failed")
            } else {
                $null = $prog.Log.Add("  No auto-install applications selected")
            }
        } catch {
            $errors += "AppInstall: $($_.Exception.Message)"
            $null = $prog.Log.Add("  [ERROR] AppInstall: $($_.Exception.Message)")
        }
        $prog.Percent = 50
        $prog.Succeeded = $succeeded
        $prog.Failed = $failed

        # Phase 2: Restore user data (50-65%)
        $prog.Phase = 'Restoring user data...'
        $prog.Percent = 52
        $null = $prog.Log.Add('[Phase 2/6] Restoring user data...')
        try {
            $dataDir = Join-Path $State.PackagePath "UserData"
            if (Test-Path $dataDir) {
                $prog.Item = "User data folders"
                $State.UserData = Import-UserProfile -Items $State.UserData -PackagePath $dataDir
                $succeeded += @($State.UserData | Where-Object { $_.ExportStatus -eq 'Success' }).Count
                $failed += @($State.UserData | Where-Object { $_.ExportStatus -eq 'Failed' }).Count
                $null = $prog.Log.Add("  User data restored")
            } else {
                $null = $prog.Log.Add("  No user data directory in package")
            }
        } catch {
            $errors += "UserData: $($_.Exception.Message)"
            $null = $prog.Log.Add("  [ERROR] UserData: $($_.Exception.Message)")
            $failed++
        }
        $prog.Percent = 65
        $prog.Succeeded = $succeeded
        $prog.Failed = $failed

        # Phase 3: Restore browser profiles (65-75%)
        $prog.Phase = 'Restoring browser profiles...'
        $prog.Percent = 66
        $null = $prog.Log.Add('[Phase 3/6] Restoring browser profiles...')
        try {
            $browserDir = Join-Path $State.PackagePath "BrowserProfiles"
            if (Test-Path $browserDir) {
                $selectedBrowsers = @($State.BrowserProfiles | Where-Object { $_.Selected })
                # Convert hashtables to BrowserProfile objects if needed
                $browserItems = @()
                foreach ($bp in $selectedBrowsers) {
                    if ($bp -is [BrowserProfile]) { $browserItems += $bp; continue }
                    $obj = [BrowserProfile]::new()
                    $obj.Browser = $bp.Browser
                    $obj.ProfileName = $bp.ProfileName
                    $obj.ProfilePath = if ($bp.Path) { $bp.Path } elseif ($bp.ProfilePath) { $bp.ProfilePath } else { '' }
                    $obj.Selected = $true
                    $browserItems += $obj
                }
                $selectedBrowsers = $browserItems
                foreach ($profile in $selectedBrowsers) {
                    $profileDir = Join-Path $browserDir "$($profile.Browser)_$($profile.ProfileName)"
                    if (Test-Path $profileDir) {
                        try {
                            $prog.Item = "$($profile.Browser) - $($profile.ProfileName)"
                            switch ($profile.Browser) {
                                'Chrome'  { Import-ChromeProfile -Profile $profile -PackagePath $profileDir }
                                'Edge'    { Import-EdgeProfile -Profile $profile -PackagePath $profileDir }
                                'Firefox' { Import-FirefoxProfile -Profile $profile -PackagePath $profileDir }
                                'Brave'   { Import-BraveProfile -Profile $profile -PackagePath $profileDir }
                            }
                            $succeeded++
                            $null = $prog.Log.Add("  Restored: $($profile.Browser) - $($profile.ProfileName)")
                        } catch {
                            $errors += "Browser $($profile.Browser): $($_.Exception.Message)"
                            $null = $prog.Log.Add("  [ERROR] $($profile.Browser): $($_.Exception.Message)")
                            $failed++
                        }
                    }
                }
            } else {
                $null = $prog.Log.Add("  No browser profiles directory in package")
            }
        } catch {
            $errors += "BrowserProfiles: $($_.Exception.Message)"
            $null = $prog.Log.Add("  [ERROR] BrowserProfiles: $($_.Exception.Message)")
        }
        $prog.Percent = 75
        $prog.Succeeded = $succeeded
        $prog.Failed = $failed

        # Phase 4: Restore system settings (75-85%)
        $prog.Phase = 'Restoring system settings...'
        $prog.Percent = 76
        $null = $prog.Log.Add('[Phase 4/6] Restoring system settings...')
        try {
            $settingsDir = Join-Path $State.PackagePath "SystemSettings"
            if (Test-Path $settingsDir) {
                $wifiSettings = $State.SystemSettings | Where-Object { $_.Category -eq 'WiFi' -and $_.Selected }
                if ($wifiSettings) {
                    $prog.Item = "WiFi profiles"
                    Import-WiFiProfiles -PackagePath (Join-Path $settingsDir "WiFi") -Settings $wifiSettings
                    $null = $prog.Log.Add("  Restored WiFi profiles")
                }

                $printerSettings = $State.SystemSettings | Where-Object { $_.Category -eq 'Printer' -and $_.Selected }
                if ($printerSettings) {
                    $prog.Item = "Printer configs"
                    Import-PrinterConfigs -Settings $printerSettings
                    $null = $prog.Log.Add("  Restored printer configs")
                }

                $driveSettings = $State.SystemSettings | Where-Object { $_.Category -eq 'MappedDrive' -and $_.Selected }
                if ($driveSettings) {
                    $prog.Item = "Mapped drives"
                    Import-MappedDrives -Settings $driveSettings
                    $null = $prog.Log.Add("  Restored mapped drives")
                }

                $envSettings = $State.SystemSettings | Where-Object { $_.Category -eq 'EnvVar' -and $_.Selected }
                if ($envSettings) {
                    $prog.Item = "Environment variables"
                    Import-EnvironmentVariables -Settings $envSettings
                    $null = $prog.Log.Add("  Restored environment variables")
                }

                $winSettings = $State.SystemSettings | Where-Object { $_.Category -eq 'WindowsSetting' -and $_.Selected }
                if ($winSettings) {
                    $prog.Item = "Windows settings"
                    # Apply cross-OS transformations if needed
                    if ($State.IsCrossOSMigration -and $State.Manifest.SourceOSContext -and $State.TargetOSContext) {
                        try {
                            . (Join-Path $MigratorRoot "Core\Convert-CrossOSSettings.ps1")
                            $crossResult = Convert-CrossOSSettings -SourceOSContext $State.Manifest.SourceOSContext -TargetOSContext $State.TargetOSContext -Settings $winSettings
                            $winSettings = $crossResult.Settings
                            foreach ($w in $crossResult.Warnings) { $null = $prog.Log.Add("  [CROSS-OS] $w") }
                        } catch {
                            $null = $prog.Log.Add("  [WARN] Cross-OS transform: $($_.Exception.Message)")
                        }
                    }
                    Import-WindowsSettings -PackagePath (Join-Path $settingsDir "WindowsSettings") -Settings $winSettings
                    $null = $prog.Log.Add("  Restored Windows settings")
                }

                # Restore new settings categories (Phase 1 additions)
                $accessSettings = $State.SystemSettings | Where-Object { $_.Category -eq 'Accessibility' -and $_.Selected }
                if ($accessSettings) {
                    $prog.Item = "Accessibility settings"
                    Import-AccessibilitySettings -PackagePath (Join-Path $settingsDir "Accessibility") -Settings $accessSettings
                    $null = $prog.Log.Add("  Restored accessibility settings")
                }

                $regionalSettings = $State.SystemSettings | Where-Object { $_.Category -eq 'Regional' -and $_.Selected }
                if ($regionalSettings) {
                    $prog.Item = "Regional settings"
                    Import-RegionalSettings -PackagePath (Join-Path $settingsDir "Regional") -Settings $regionalSettings
                    $null = $prog.Log.Add("  Restored regional settings")
                }

                $vpnSettings = $State.SystemSettings | Where-Object { $_.Category -eq 'VPN' -and $_.Selected }
                if ($vpnSettings) {
                    $prog.Item = "VPN connections"
                    Import-VPNConnections -PackagePath (Join-Path $settingsDir "VPN") -Settings $vpnSettings
                    $null = $prog.Log.Add("  Restored VPN connections")
                }

                $certSettings = $State.SystemSettings | Where-Object { $_.Category -eq 'Certificate' -and $_.Selected }
                if ($certSettings) {
                    $prog.Item = "User certificates"
                    Import-UserCertificates -PackagePath (Join-Path $settingsDir "Certificates") -Settings $certSettings
                    $null = $prog.Log.Add("  Restored user certificates")
                }

                $odbcSettings = $State.SystemSettings | Where-Object { $_.Category -eq 'ODBC' -and $_.Selected }
                if ($odbcSettings) {
                    $prog.Item = "ODBC data sources"
                    Import-ODBCSettings -PackagePath (Join-Path $settingsDir "ODBC") -Settings $odbcSettings
                    $null = $prog.Log.Add("  Restored ODBC data sources")
                }

                $folderSettings = $State.SystemSettings | Where-Object { $_.Category -eq 'FolderOption' -and $_.Selected }
                if ($folderSettings) {
                    $prog.Item = "Folder options"
                    Import-FolderOptions -PackagePath (Join-Path $settingsDir "FolderOptions") -Settings $folderSettings
                    $null = $prog.Log.Add("  Restored folder options")
                }

                $inputSettings = $State.SystemSettings | Where-Object { $_.Category -eq 'InputSetting' -and $_.Selected }
                if ($inputSettings) {
                    $prog.Item = "Input settings"
                    Import-InputSettings -PackagePath (Join-Path $settingsDir "InputSettings") -Settings $inputSettings
                    $null = $prog.Log.Add("  Restored input settings")
                }

                $powerSettings = $State.SystemSettings | Where-Object { $_.Category -eq 'PowerPlan' -and $_.Selected }
                if ($powerSettings) {
                    $prog.Item = "Power plan"
                    Import-PowerSettings -PackagePath (Join-Path $settingsDir "PowerPlan") -Settings $powerSettings
                    $null = $prog.Log.Add("  Restored power plan")
                }

                $succeeded += @($State.SystemSettings | Where-Object { $_.ImportStatus -eq 'Success' }).Count
                $failed += @($State.SystemSettings | Where-Object { $_.ImportStatus -eq 'Failed' }).Count
            } else {
                $null = $prog.Log.Add("  No system settings directory in package")
            }
        } catch {
            $errors += "SystemSettings: $($_.Exception.Message)"
            $null = $prog.Log.Add("  [ERROR] SystemSettings: $($_.Exception.Message)")
        }
        $prog.Percent = 85
        $prog.Succeeded = $succeeded
        $prog.Failed = $failed

        # Phase 5: Restore AppData (85-90%)
        $prog.Phase = 'Restoring AppData settings...'
        $prog.Percent = 86
        $null = $prog.Log.Add('[Phase 5/6] Restoring AppData settings...')
        try {
            $appDataDir = Join-Path $State.PackagePath "AppData"
            if (Test-Path $appDataDir) {
                $prog.Item = "AppData"
                # Filter UserData for AppData-category items
                $appDataItems = @($State.UserData | Where-Object { $_.Category -eq 'AppData' })
                if ($appDataItems.Count -gt 0) {
                    Import-AppDataSettings -Items $appDataItems -PackagePath $State.PackagePath
                    $succeeded += @($appDataItems | Where-Object { $_.ExportStatus -eq 'Success' }).Count
                    $failed += @($appDataItems | Where-Object { $_.ExportStatus -eq 'Failed' }).Count
                    $null = $prog.Log.Add("  Restored $($appDataItems.Count) AppData items")
                } else {
                    $null = $prog.Log.Add("  No AppData items in manifest (directory exists but no items)")
                }
            } else {
                $null = $prog.Log.Add("  No AppData directory in package")
            }
        } catch {
            $errors += "AppData: $($_.Exception.Message)"
            $null = $prog.Log.Add("  [ERROR] AppData: $($_.Exception.Message)")
        }

        # Phase 5.5: Restore Application Profiles (90-93%)
        $prog.Phase = 'Restoring application profiles...'
        $prog.Percent = 90
        $null = $prog.Log.Add('[Phase 5.5/6] Restoring application profiles...')
        try {
            $profilesDir = Join-Path $State.PackagePath "AppProfiles"
            if ((Test-Path $profilesDir) -and $State.AppProfiles -and $State.AppProfiles.Count -gt 0) {
                $prog.Item = "Application profiles"
                $importedProfiles = Import-AppProfiles -SourcePath $profilesDir -Profiles $State.AppProfiles
                $succeeded += $importedProfiles
                $null = $prog.Log.Add("  Restored $importedProfiles application profiles")
            } else {
                $null = $prog.Log.Add("  No application profiles to restore")
            }
        } catch {
            $errors += "AppProfiles: $($_.Exception.Message)"
            $null = $prog.Log.Add("  [ERROR] AppProfiles: $($_.Exception.Message)")
        }
        $prog.Percent = 93
        $prog.Succeeded = $succeeded
        $prog.Failed = $failed

        # Phase 6: Generate reports (93-100%)
        $prog.Phase = 'Generating reports...'
        $prog.Percent = 95
        $prog.Item = "Reports"
        $null = $prog.Log.Add('[Phase 6/6] Generating reports...')
        try {
            $reportDir = Join-Path $State.PackagePath "Reports"
            New-Item -Path $reportDir -ItemType Directory -Force | Out-Null

            $manualApps = $State.Apps | Where-Object { $_.InstallMethod -eq 'Manual' -or $_.InstallStatus -eq 'Failed' }
            if ($manualApps) {
                $State['ManualReportPath'] = New-ManualInstallReport -Apps $manualApps -OutputDirectory $reportDir
            }
            $State['CompletionReportPath'] = New-CompletionReport -Manifest $State.Manifest -OutputDirectory $reportDir
            $null = $prog.Log.Add("  Reports generated")
        } catch {
            $errors += "Reports: $($_.Exception.Message)"
            $null = $prog.Log.Add("  [ERROR] Reports: $($_.Exception.Message)")
        }

        # Write progress file for external monitoring
        try {
            @{
                phase       = 'complete'
                percent     = 100
                currentItem = ''
                succeeded   = $succeeded
                failed      = $failed
                errors      = $errors
                timestamp   = (Get-Date).ToString('o')
            } | ConvertTo-Json | Set-Content (Join-Path $State.PackagePath "progress.json") -Encoding UTF8
        } catch {}

        $prog.Phase = 'Import complete!'
        $prog.Percent = 100
        $prog.Item = ''
        $prog.Done = $true
        $prog.Succeeded = $succeeded
        $prog.Failed = $failed
        $prog.Remaining = 0

        return @{
            Success   = $true
            Succeeded = $succeeded
            Failed    = $failed
            Errors    = $errors
        }
    }) | Out-Null

    $handle = $ps.BeginInvoke()
    $ctx.Job = @{ PowerShell = $ps; Handle = $handle; Runspace = $runspace }
    # Register with $State so MainWindow cleanup can stop this on window close
    $State.ActiveJob = $ctx.Job

    # Timer-driven progress polling
    $State.OnTick = {
        param($s)
        $p = $ctx.Progress

        # Update progress bar and labels from synchronized hashtable
        if ($p.Percent -gt $ui.Progress.Value) {
            $ui.Progress.Value = $p.Percent
            $ui.Percent.Text = "$($p.Percent)%"
        }
        if ($p.Phase) { $ui.Phase.Text = $p.Phase }
        if ($p.Item) { $ui.Current.Text = $p.Item }
        $ui.Success.Text = "$($p.Succeeded)"
        $ui.Failed.Text = "$($p.Failed)"
        $ui.Remaining.Text = "$($p.Remaining)"

        # Append new log entries
        $logCount = $p.Log.Count
        if ($logCount -gt $ctx.LastLogIdx) {
            for ($i = $ctx.LastLogIdx; $i -lt $logCount; $i++) {
                $ui.Log.AppendText("$($p.Log[$i])`r`n")
            }
            $ui.Log.ScrollToEnd()
            $ctx.LastLogIdx = $logCount
        }

        # Check for completion
        $job = $ctx.Job
        if ($job -and $job.Handle.IsCompleted) {
            try {
                $result = $job.PowerShell.EndInvoke($job.Handle)
                $ui.Title.Text = "Import Complete!"
                $ui.Phase.Text = "Your migration is finished."
                $ui.Progress.Value = 100
                $ui.Percent.Text = "100%"
                $ui.Current.Text = ""
                $ui.Success.Text = "$($p.Succeeded)"
                $ui.Failed.Text = "$($p.Failed)"
                $ui.Remaining.Text = "0"
                $s.BtnNext.IsEnabled = $true
                $s.BtnNext.Content = "Next"
                if ($result -and $result.Errors -and $result.Errors.Count -gt 0) {
                    $ui.Log.AppendText("Completed with $($result.Errors.Count) warning(s)`r`n")
                    foreach ($err in $result.Errors) {
                        $ui.Log.AppendText("  WARNING: $err`r`n")
                    }
                    $ui.Log.ScrollToEnd()
                }
            } catch {
                $ui.Title.Text = "Import Failed"
                $ui.Phase.Text = $_.Exception.Message
                try { $ui.Progress.Foreground = $Page.FindResource('ErrorBrush') } catch {}
                $s.BtnBack.IsEnabled = $true
            } finally {
                try {
                    $job.PowerShell.Dispose()
                    $job.Runspace.Close()
                    $job.Runspace.Dispose()
                } catch {}
                $ctx.Job = $null
                $s.ActiveJob = $null
                $s.OnTick = $null
            }
        }
    }.GetNewClosure()
}
