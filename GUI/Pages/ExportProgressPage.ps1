<#
========================================================================================================
    Title:          Win11Migrator - Export Progress Page
    Filename:       ExportProgressPage.ps1
    Description:    Shows real-time progress during the migration package export process.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-ExportProgressPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    # Store all controls in a single hashtable so closures capture them via .GetNewClosure()
    $ui = @{
        Title     = $Page.FindName('txtExportTitle')
        Phase     = $Page.FindName('txtExportPhase')
        Progress  = $Page.FindName('progressExport')
        Percent   = $Page.FindName('txtExportPercent')
        Current   = $Page.FindName('txtCurrentItem')
        Log       = $Page.FindName('txtExportLog')
    }

    # Disable navigation during export
    $State.BtnNext.IsEnabled = $false
    $State.BtnBack.IsEnabled = $false

    # Create package directory
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $pkgName = "Win11Migration_$($env:COMPUTERNAME)_$timestamp"
    $localPkgPath = Join-Path $State.Config.PackagePath $pkgName
    New-Item -Path $localPkgPath -ItemType Directory -Force | Out-Null
    $State.PackagePath = $localPkgPath

    # Synchronized hashtable for progress reporting from background thread
    $exportProgress = [hashtable]::Synchronized(@{
        Phase   = 'Preparing...'
        Percent = 0
        Item    = ''
        Log     = [System.Collections.ArrayList]::new()
        Done    = $false
    })

    # Wrap the job reference in a hashtable so closures capture it properly
    $ctx = @{ Job = $null; Progress = $exportProgress }

    # Start export in a background runspace
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('State', $State)
    $runspace.SessionStateProxy.SetVariable('LocalPkgPath', $localPkgPath)
    $runspace.SessionStateProxy.SetVariable('prog', $exportProgress)
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
        Get-ChildItem (Join-Path $MigratorRoot "Modules\UserData\*.ps1") | ForEach-Object { . $_.FullName }
        Get-ChildItem (Join-Path $MigratorRoot "Modules\BrowserProfiles\*.ps1") | ForEach-Object { . $_.FullName }
        Get-ChildItem (Join-Path $MigratorRoot "Modules\SystemSettings\*.ps1") | ForEach-Object { . $_.FullName }
        Get-ChildItem (Join-Path $MigratorRoot "Modules\AppProfiles\*.ps1") | ForEach-Object { . $_.FullName }
        Get-ChildItem (Join-Path $MigratorRoot "Modules\StorageTargets\*.ps1") | ForEach-Object { . $_.FullName }

        # Set script-scope variables that modules depend on
        $script:MigratorRoot = $MigratorRoot
        $script:Config = $Config

        $errors = @()

        # Phase 1: Export user data (0-25%)
        $prog.Phase = 'Exporting user data...'
        $prog.Percent = 5
        $null = $prog.Log.Add('[Phase 1/7] Exporting user data...')
        try {
            $dataDir = Join-Path $LocalPkgPath "UserData"
            New-Item -Path $dataDir -ItemType Directory -Force | Out-Null
            $selectedData = @($State.UserData | Where-Object { $_.Selected })
            # Convert hashtables from scan page to UserDataItem objects
            $items = @()
            $skippedCloud = @()
            foreach ($d in $selectedData) {
                if ($d -is [UserDataItem]) {
                    if ($d.SkipCloudSync) { $d.ExportStatus = 'Skipped'; $skippedCloud += $d; continue }
                    $items += $d; continue
                }
                $item = [UserDataItem]::new()
                $item.SourcePath = $d.SourcePath
                $item.RelativePath = if ($d.Name) { $d.Name } else { $d.RelativePath }
                $item.Category = if ($d.Name) { $d.Name } else { $d.Category }
                $item.Selected = $true
                $item.IsCustom = if ($d.IsCustom) { $true } else { $false }
                $item.IsCloudSynced = if ($d.IsCloudSynced) { $true } else { $false }
                $item.CloudProvider = if ($d.CloudProvider) { $d.CloudProvider } else { '' }
                $item.SkipCloudSync = if ($d.SkipCloudSync) { $true } else { $false }
                if ($item.SkipCloudSync) {
                    $item.ExportStatus = 'Skipped'
                    $skippedCloud += $item
                    continue
                }
                $items += $item
            }
            if ($skippedCloud.Count -gt 0) {
                $null = $prog.Log.Add("  Skipping $($skippedCloud.Count) cloud-synced folder(s) (will re-sync on new PC)")
                foreach ($sk in $skippedCloud) {
                    $null = $prog.Log.Add("    Skipped: $($sk.Category) ($($sk.CloudProvider))")
                }
            }
            $prog.Item = "User data folders"
            $exportedItems = Export-UserProfile -Items $items -OutputDirectory $dataDir
            # Merge exported items with skipped cloud items for manifest
            $State.UserData = @($exportedItems) + @($skippedCloud)
            $prog.Percent = 25
            $null = $prog.Log.Add("  Exported $($items.Count) user data folders, skipped $($skippedCloud.Count) cloud-synced")
        } catch {
            $errors += "UserData: $($_.Exception.Message)"
            $null = $prog.Log.Add("  [ERROR] UserData: $($_.Exception.Message)")
        }

        # Phase 2: Export browser profiles (25-40%)
        $prog.Phase = 'Exporting browser profiles...'
        $prog.Percent = 28
        $null = $prog.Log.Add('[Phase 2/7] Exporting browser profiles...')
        try {
            $browserDir = Join-Path $LocalPkgPath "BrowserProfiles"
            New-Item -Path $browserDir -ItemType Directory -Force | Out-Null
            $selectedBrowsers = @($State.BrowserProfiles | Where-Object { $_.Selected })
            # Convert hashtables to BrowserProfile objects if needed
            $browserItems = @()
            foreach ($bp in $selectedBrowsers) {
                if ($bp -is [BrowserProfile]) { $browserItems += $bp; continue }
                $obj = [BrowserProfile]::new()
                $obj.Browser = $bp.Browser
                $obj.ProfileName = $bp.ProfileName
                $obj.ProfilePath = if ($bp.ProfilePath) { $bp.ProfilePath } else { '' }
                $obj.Selected = $true
                $browserItems += $obj
            }
            $selectedBrowsers = $browserItems
            $bIdx = 0
            foreach ($profile in $selectedBrowsers) {
                $bIdx++
                $prog.Item = "$($profile.Browser) - $($profile.ProfileName)"
                $prog.Percent = 28 + [Math]::Floor(($bIdx / [Math]::Max($selectedBrowsers.Count, 1)) * 12)
                $profileDir = Join-Path $browserDir "$($profile.Browser)_$($profile.ProfileName)"
                New-Item -Path $profileDir -ItemType Directory -Force | Out-Null
                switch ($profile.Browser) {
                    'Chrome'  { Export-ChromeProfile -Profile $profile -OutputDirectory $profileDir }
                    'Edge'    { Export-EdgeProfile -Profile $profile -OutputDirectory $profileDir }
                    'Firefox' { Export-FirefoxProfile -Profile $profile -OutputDirectory $profileDir }
                    'Brave'   { Export-BraveProfile -Profile $profile -OutputDirectory $profileDir }
                }
                $null = $prog.Log.Add("  Exported: $($profile.Browser) - $($profile.ProfileName)")
            }
        } catch {
            $errors += "BrowserProfiles: $($_.Exception.Message)"
            $null = $prog.Log.Add("  [ERROR] BrowserProfiles: $($_.Exception.Message)")
        }

        # Phase 3: Export system settings (40-55%)
        $prog.Phase = 'Exporting system settings...'
        $prog.Percent = 42
        $null = $prog.Log.Add('[Phase 3/7] Exporting system settings...')
        $settingsDir = Join-Path $LocalPkgPath "SystemSettings"
        New-Item -Path $settingsDir -ItemType Directory -Force | Out-Null
        $settings = @()
        $settingsExports = @(
            @{ Flag = 'IncludeWiFi';          Label = 'WiFi profiles';          Func = 'Export-WiFiProfiles';          Sub = 'WiFi';              Pct = 42 }
            @{ Flag = 'IncludePrinters';      Label = 'Printer configs';        Func = 'Export-PrinterConfigs';        Sub = 'Printers';          Pct = 43 }
            @{ Flag = 'IncludeDrives';        Label = 'Mapped drives';          Func = 'Export-MappedDrives';          Sub = 'MappedDrives';      Pct = 44 }
            @{ Flag = 'IncludeEnvVars';       Label = 'Environment variables';  Func = 'Export-EnvironmentVariables';  Sub = 'EnvVars';           Pct = 45 }
            @{ Flag = 'IncludeWinSettings';   Label = 'Windows settings';       Func = 'Export-WindowsSettings';       Sub = 'WindowsSettings';   Pct = 46 }
            @{ Flag = 'IncludeAccessibility'; Label = 'Accessibility settings'; Func = 'Export-AccessibilitySettings'; Sub = 'Accessibility';     Pct = 47 }
            @{ Flag = 'IncludeRegional';      Label = 'Regional settings';      Func = 'Export-RegionalSettings';      Sub = 'Regional';          Pct = 48 }
            @{ Flag = 'IncludeVPN';           Label = 'VPN connections';        Func = 'Export-VPNConnections';        Sub = 'VPN';               Pct = 49 }
            @{ Flag = 'IncludeCertificates';  Label = 'User certificates';      Func = 'Export-UserCertificates';      Sub = 'Certificates';      Pct = 50 }
            @{ Flag = 'IncludeODBC';          Label = 'ODBC data sources';      Func = 'Export-ODBCSettings';          Sub = 'ODBC';              Pct = 51 }
            @{ Flag = 'IncludeFolderOptions'; Label = 'Folder options';         Func = 'Export-FolderOptions';         Sub = 'FolderOptions';     Pct = 52 }
            @{ Flag = 'IncludeInputSettings'; Label = 'Input settings';         Func = 'Export-InputSettings';         Sub = 'InputSettings';     Pct = 53 }
            @{ Flag = 'IncludePower';         Label = 'Power plan';             Func = 'Export-PowerSettings';         Sub = 'PowerPlan';         Pct = 54 }
        )
        foreach ($exp in $settingsExports) {
            if ($State[$exp.Flag]) {
                $prog.Item = $exp.Label
                try {
                    $result = & $exp.Func -ExportPath (Join-Path $settingsDir $exp.Sub)
                    if ($result) { $settings += $result }
                } catch {
                    $null = $prog.Log.Add("  [WARN] $($exp.Label): $($_.Exception.Message)")
                }
                $prog.Percent = $exp.Pct
            }
        }
        $State.SystemSettings = $settings
        $null = $prog.Log.Add("  Exported $($settings.Count) system setting(s)")

        # Phase 3.5: USMT ScanState (if available)
        if ($Config.USMTAvailable -and $Config.USMTPath) {
            $prog.Phase = 'Running USMT ScanState...'
            $prog.Percent = 55
            $prog.Item = 'USMT deep settings capture'
            $null = $prog.Log.Add('[Phase 3.5/7] Running USMT ScanState...')
            try {
                . (Join-Path $MigratorRoot "Modules\USMT\Test-USMTAvailability.ps1")
                . (Join-Path $MigratorRoot "Modules\USMT\Invoke-USMTScanState.ps1")
                . (Join-Path $MigratorRoot "Modules\USMT\New-USMTCustomXml.ps1")
                $usmt = Test-USMTAvailability
                if ($usmt.Available) {
                    $usmtStore = Join-Path $LocalPkgPath "USMTStore"
                    New-Item -Path $usmtStore -ItemType Directory -Force | Out-Null
                    $usmtXmls = @($usmt.MigAppXml, $usmt.MigDocsXml, $usmt.MigUserXml) | Where-Object { $_ -and (Test-Path $_) }
                    $usmtLog = Join-Path $LocalPkgPath "usmt_scanstate.log"
                    $usmtResult = Invoke-USMTScanState -ScanStatePath $usmt.ScanStatePath -StorePath $usmtStore -MigrationXmls $usmtXmls -LogPath $usmtLog
                    if ($usmtResult.Success) {
                        $null = $prog.Log.Add("  USMT ScanState completed successfully")
                        $State['USMTStorePresent'] = $true
                    } else {
                        $null = $prog.Log.Add("  USMT ScanState failed (exit code $($usmtResult.ExitCode)): $($usmtResult.ErrorMessage)")
                    }
                }
            } catch {
                $null = $prog.Log.Add("  [WARN] USMT ScanState: $($_.Exception.Message)")
            }
        }

        # Phase 4: Export AppData (55-65%)
        $prog.Phase = 'Exporting AppData settings...'
        $prog.Percent = 56
        $null = $prog.Log.Add('[Phase 4/7] Exporting AppData settings...')
        try {
            $prog.Item = "AppData"
            $appDataDir = Join-Path $LocalPkgPath "AppData"
            New-Item -Path $appDataDir -ItemType Directory -Force | Out-Null
            $appDataItems = Export-AppDataSettings -OutputDirectory $appDataDir
            if ($appDataItems -and $appDataItems.Count -gt 0) {
                # Add AppData items to UserData so they appear in the manifest
                $State.UserData = @($State.UserData) + @($appDataItems)
                $null = $prog.Log.Add("  Exported $($appDataItems.Count) AppData items")
            } else {
                $null = $prog.Log.Add("  No AppData items to export")
            }
            $prog.Percent = 63
        } catch {
            $errors += "AppData: $($_.Exception.Message)"
            $null = $prog.Log.Add("  [ERROR] AppData: $($_.Exception.Message)")
        }

        # Phase 5: Export Application Profiles (65-78%)
        $prog.Phase = 'Exporting application profiles...'
        $prog.Percent = 66
        $null = $prog.Log.Add('[Phase 5/7] Exporting application profiles...')
        try {
            $selectedProfiles = @($State.AppProfiles | Where-Object { $_.Selected })
            if ($selectedProfiles.Count -gt 0) {
                $profilesDir = Join-Path $LocalPkgPath "AppProfiles"
                New-Item -Path $profilesDir -ItemType Directory -Force | Out-Null
                $pIdx = 0
                foreach ($profile in $selectedProfiles) {
                    $pIdx++
                    $prog.Item = $profile.Name
                    $prog.Percent = 66 + [Math]::Floor(($pIdx / [Math]::Max($selectedProfiles.Count, 1)) * 12)
                }
                Export-AppProfiles -Profiles $selectedProfiles -OutputPath $profilesDir
                $null = $prog.Log.Add("  Exported $($selectedProfiles.Count) application profiles")
            } else {
                $null = $prog.Log.Add("  No application profiles selected")
            }
        } catch {
            $errors += "AppProfiles: $($_.Exception.Message)"
            $null = $prog.Log.Add("  [ERROR] AppProfiles: $($_.Exception.Message)")
        }

        # Phase 6: Write manifest (78-88%)
        $prog.Phase = 'Writing migration manifest...'
        $prog.Percent = 80
        $prog.Item = "manifest.json"
        $null = $prog.Log.Add('[Phase 6/7] Writing migration manifest...')
        try {
            $selectedApps = $State.Apps | Where-Object { $_.Selected }
            $selectedProfiles = @($State.AppProfiles | Where-Object { $_.Selected })
            ConvertTo-MigrationManifest -OutputPath $LocalPkgPath `
                -Apps $selectedApps `
                -UserData $State.UserData `
                -BrowserProfiles ($State.BrowserProfiles | Where-Object { $_.Selected }) `
                -SystemSettings $State.SystemSettings `
                -AppProfiles $selectedProfiles `
                -Metadata @{ Errors = $errors }
            $prog.Percent = 86
            $null = $prog.Log.Add("  Manifest written with $(@($selectedApps).Count) apps")
        } catch {
            $errors += "Manifest: $($_.Exception.Message)"
            $null = $prog.Log.Add("  [ERROR] Manifest: $($_.Exception.Message)")
        }

        # Phase 7: Transfer to storage target (86-100%)
        if ($State.StorageTarget) {
            $prog.Phase = "Transferring to $($State.StorageTarget.Type)..."
            $prog.Percent = 88
            $prog.Item = $State.StorageTarget.Path
            $null = $prog.Log.Add("[Phase 7/7] Transferring to $($State.StorageTarget.Type)...")
            try {
                switch ($State.StorageTarget.Type) {
                    'USB'          { Export-ToUSBDrive -PackagePath $LocalPkgPath -TargetDriveLetter $State.StorageTarget.Path }
                    'OneDrive'     { Export-ToOneDrive -PackagePath $LocalPkgPath -OneDrivePath $State.StorageTarget.Path }
                    'GoogleDrive'  { Export-ToGoogleDrive -PackagePath $LocalPkgPath -GoogleDrivePath $State.StorageTarget.Path }
                    'NetworkShare' { Export-ToNetworkShare -PackagePath $LocalPkgPath -NetworkPath $State.StorageTarget.Path }
                    'Custom'       { Export-ToUSBDrive -PackagePath $LocalPkgPath -TargetDriveLetter $State.StorageTarget.Path }
                    'NetworkDirect' {
                        . (Join-Path $MigratorRoot "Modules\NetworkTransfer\Push-MigrationDirect.ps1")
                        . (Join-Path $MigratorRoot "Modules\NetworkTransfer\Initialize-RemoteProfile.ps1")
                        . (Join-Path $MigratorRoot "Modules\NetworkTransfer\Install-AppsRemotely.ps1")
                        $pushResult = Push-MigrationDirect -ComputerName $State.NetworkTarget.ComputerName `
                            -Credential $State.NetworkTarget.Credential `
                            -TargetUserName $State.NetworkTarget.TargetUserName `
                            -State $State -Progress $prog
                        if (-not $pushResult.Success) {
                            $errors += "NetworkDirect: $($pushResult.Errors -join '; ')"
                        }
                        $State['RemoteRestoreLaunched'] = $pushResult.RemoteRestoreLaunched
                    }
                }
                $null = $prog.Log.Add("  Transfer complete")
                # Encrypt package if enabled
                if ($State.EncryptPackage -and $State.EncryptPassword) {
                    $prog.Phase = 'Encrypting migration package...'
                    $prog.Percent = 96
                    $prog.Item = 'AES-256 encryption'
                    $null = $prog.Log.Add('  Encrypting migration package...')
                    try {
                        . (Join-Path $MigratorRoot "Core\Protect-MigrationPackage.ps1")
                        $encResult = Protect-MigrationPackage -PackagePath $LocalPkgPath -Password $State.EncryptPassword
                        if ($encResult.Success) {
                            $null = $prog.Log.Add("  Package encrypted: $($encResult.OutputFile)")
                            $State['EncryptedPackagePath'] = $encResult.OutputFile
                        }
                    } catch {
                        $errors += "Encryption: $($_.Exception.Message)"
                        $null = $prog.Log.Add("  [ERROR] Encryption: $($_.Exception.Message)")
                    }
                }
            } catch {
                $errors += "Transfer: $($_.Exception.Message)"
                $null = $prog.Log.Add("  [ERROR] Transfer: $($_.Exception.Message)")
            }
        } else {
            $null = $prog.Log.Add('[Phase 7/7] No storage target selected (local only)')
        }

        # Write progress file for external monitoring
        try {
            @{
                phase       = 'complete'
                percent     = 100
                currentItem = ''
                succeeded   = @($State.Apps | Where-Object { $_.Selected }).Count
                failed      = $errors.Count
                errors      = $errors
                timestamp   = (Get-Date).ToString('o')
            } | ConvertTo-Json | Set-Content (Join-Path $LocalPkgPath "progress.json") -Encoding UTF8
        } catch {}

        $prog.Phase = 'Export complete!'
        $prog.Percent = 100
        $prog.Item = ''
        $prog.Done = $true

        return @{ Success = $true; Errors = $errors; PackagePath = $LocalPkgPath }
    }) | Out-Null

    $handle = $ps.BeginInvoke()
    $ctx.Job = @{ PowerShell = $ps; Handle = $handle; Runspace = $runspace }
    # Register with $State so MainWindow cleanup can stop this on window close
    $State.ActiveJob = $ctx.Job

    # Track last log index so we only append new entries
    $ctx['LastLogIdx'] = 0

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
                $ui.Title.Text = "Export Complete!"
                $ui.Phase.Text = "Your migration package is ready."
                $ui.Progress.Value = 100
                $ui.Percent.Text = "100%"
                $ui.Current.Text = ""
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
                $ui.Title.Text = "Export Failed"
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
