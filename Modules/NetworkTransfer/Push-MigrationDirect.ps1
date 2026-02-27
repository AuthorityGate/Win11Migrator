<#
========================================================================================================
    Title:          Win11Migrator - Direct Push Migration Orchestrator
    Filename:       Push-MigrationDirect.ps1
    Description:    Orchestrates a direct push migration to a target machine over the network.
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
    Pushes a complete migration package directly to a target machine over the network.
.DESCRIPTION
    Orchestrates the end-to-end direct network transfer by resolving the remote user
    profile, copying user data via Robocopy to UNC paths, pushing browser profiles,
    applying system settings via remote registry, triggering app installs, and writing
    the migration manifest to the target for record-keeping.
.PARAMETER ComputerName
    Hostname or IP address of the target computer.
.PARAMETER Credential
    PSCredential for authenticating to the target machine.
.PARAMETER TargetUserName
    The username on the target whose profile will receive the migrated data.
.PARAMETER State
    The migration state hashtable containing Apps, UserDataItems, BrowserProfiles,
    SystemSettings, and Manifest.
.PARAMETER Progress
    Optional synchronized hashtable for reporting progress to the UI thread.
.OUTPUTS
    [hashtable] With Success, Errors, UserDataPushed, AppsPushed, SettingsPushed keys.
.EXAMPLE
    $result = Push-MigrationDirect -ComputerName 'TARGET-PC' -Credential $cred -TargetUserName 'john' -State $State
#>

function Push-MigrationDirect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [PSCredential]$Credential,

        [Parameter(Mandatory)]
        [string]$TargetUserName,

        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter()]
        [hashtable]$Progress
    )

    Write-MigrationLog -Message "Starting direct push migration to '$ComputerName' for user '$TargetUserName'" -Level Info

    $migrationResult = @{
        Success         = $false
        Errors          = @()
        UserDataPushed  = 0
        AppsPushed      = 0
        SettingsPushed  = 0
    }

    # Helper to update progress safely
    $updateProgress = {
        param($Status, $Percent, $Detail)
        if ($Progress) {
            $Progress['Status']  = $Status
            $Progress['Percent'] = $Percent
            $Progress['Detail']  = $Detail
        }
    }

    & $updateProgress 'Initializing' 0 'Resolving target profile...'

    # -------------------------------------------------------------------------
    # 1. Resolve target profile path
    # -------------------------------------------------------------------------
    Write-MigrationLog -Message "Resolving target user profile" -Level Info
    $remoteProfile = Initialize-RemoteProfile -ComputerName $ComputerName -Credential $Credential -TargetUserName $TargetUserName

    if ([string]::IsNullOrWhiteSpace($remoteProfile.ProfilePath)) {
        $errMsg = "Failed to resolve or create profile for '$TargetUserName' on '$ComputerName': $($remoteProfile.ErrorMessage)"
        Write-MigrationLog -Message $errMsg -Level Error
        $migrationResult.Errors += $errMsg
        return $migrationResult
    }

    Write-MigrationLog -Message "Target profile resolved: $($remoteProfile.ProfilePath)" -Level Info

    # -------------------------------------------------------------------------
    # 2. Map UNC paths for common folders
    # -------------------------------------------------------------------------
    $profileRelative = $remoteProfile.ProfilePath -replace '^[A-Za-z]:', ''
    $uncBase         = "\\$ComputerName\C`$$profileRelative"
    $uncDesktop      = Join-Path $uncBase 'Desktop'
    $uncDocuments    = Join-Path $uncBase 'Documents'
    $uncDownloads    = Join-Path $uncBase 'Downloads'
    $uncPictures     = Join-Path $uncBase 'Pictures'
    $uncMusic        = Join-Path $uncBase 'Music'
    $uncVideos       = Join-Path $uncBase 'Videos'
    $uncLocalAppData = "\\$ComputerName\C`$\Users\$TargetUserName\AppData\Local"
    $uncRoamingAppData = "\\$ComputerName\C`$\Users\$TargetUserName\AppData\Roaming"

    # Map a PSDrive with credentials for UNC access
    $netDriveName = "MigratorPush_$(Get-Random)"
    try {
        $null = New-PSDrive -Name $netDriveName -PSProvider FileSystem -Root "\\$ComputerName\C`$" -Credential $Credential -ErrorAction Stop
        Write-MigrationLog -Message "Mapped network drive to \\$ComputerName\C`$" -Level Debug
    } catch {
        $errMsg = "Failed to map network drive to \\$ComputerName\C`$: $($_.Exception.Message)"
        Write-MigrationLog -Message $errMsg -Level Error
        $migrationResult.Errors += $errMsg
        return $migrationResult
    }

    # Category-to-UNC path mapping
    $categoryPaths = @{
        'Desktop'   = $uncDesktop
        'Documents' = $uncDocuments
        'Downloads' = $uncDownloads
        'Pictures'  = $uncPictures
        'Music'     = $uncMusic
        'Videos'    = $uncVideos
    }

    # Robocopy settings
    $threads = if ($script:Config -and $script:Config['RobocopyThreads'])    { $script:Config['RobocopyThreads'] }    else { 8 }
    $retries = if ($script:Config -and $script:Config['RobocopyRetries'])    { $script:Config['RobocopyRetries'] }    else { 3 }
    $waitSec = if ($script:Config -and $script:Config['RobocopyWaitSeconds']) { $script:Config['RobocopyWaitSeconds'] } else { 5 }

    # -------------------------------------------------------------------------
    # 3. Push user data via Robocopy to UNC paths
    # -------------------------------------------------------------------------
    Write-MigrationLog -Message "Pushing user data to target" -Level Info
    & $updateProgress 'Copying User Data' 10 'Transferring files to target...'

    $userDataItems = @()
    if ($State.ContainsKey('UserDataItems')) {
        $userDataItems = @($State.UserDataItems | Where-Object { $_.Selected })
    }

    $totalItems = $userDataItems.Count
    $itemIndex  = 0

    foreach ($item in $userDataItems) {
        $itemIndex++
        $pct = 10 + [math]::Floor(($itemIndex / [math]::Max($totalItems, 1)) * 30)
        & $updateProgress 'Copying User Data' $pct "[$itemIndex/$totalItems] $($item.Category)"

        # Determine target UNC path
        $targetUNC = $null
        if ($categoryPaths.ContainsKey($item.Category)) {
            $targetUNC = $categoryPaths[$item.Category]
        } else {
            # For non-standard categories, place under profile base
            $targetUNC = Join-Path $uncBase $item.Category
        }

        Write-MigrationLog -Message "Robocopy: $($item.SourcePath) -> $targetUNC" -Level Info

        try {
            # Ensure target directory exists
            if (-not (Test-Path $targetUNC)) {
                New-Item -Path $targetUNC -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }

            $robocopyArgs = @(
                "`"$($item.SourcePath)`""
                "`"$targetUNC`""
                '/E'
                "/R:$retries"
                "/W:$waitSec"
                "/MT:$threads"
                '/NP'
                '/NDL'
                '/NJH'
                '/NJS'
                '/XJ'
            )

            $robocopyOutput = & robocopy @robocopyArgs 2>&1
            $exitCode = $LASTEXITCODE

            # Robocopy exit codes: 0-7 are success/info, 8+ are errors
            if ($exitCode -lt 8) {
                $item.ExportStatus = 'Success'
                $migrationResult.UserDataPushed++
                Write-MigrationLog -Message "Robocopy completed for '$($item.Category)' (exit code: $exitCode)" -Level Info
            } else {
                $item.ExportStatus = 'Failed'
                $errMsg = "Robocopy failed for '$($item.Category)' with exit code $exitCode"
                $migrationResult.Errors += $errMsg
                Write-MigrationLog -Message $errMsg -Level Error
            }
        } catch {
            $item.ExportStatus = 'Failed'
            $errMsg = "Failed to copy '$($item.Category)': $($_.Exception.Message)"
            $migrationResult.Errors += $errMsg
            Write-MigrationLog -Message $errMsg -Level Error
        }
    }

    # -------------------------------------------------------------------------
    # 4. Push browser profiles to target AppData via UNC
    # -------------------------------------------------------------------------
    Write-MigrationLog -Message "Pushing browser profiles to target" -Level Info
    & $updateProgress 'Copying Browser Data' 45 'Transferring browser profiles...'

    $browserProfiles = @()
    if ($State.ContainsKey('BrowserProfiles')) {
        $browserProfiles = @($State.BrowserProfiles | Where-Object { $_.Selected })
    }

    foreach ($browser in $browserProfiles) {
        try {
            $browserTargetUNC = $null
            switch ($browser.BrowserName) {
                'Chrome' {
                    $browserTargetUNC = Join-Path $uncLocalAppData 'Google\Chrome\User Data'
                }
                'Edge' {
                    $browserTargetUNC = Join-Path $uncLocalAppData 'Microsoft\Edge\User Data'
                }
                'Firefox' {
                    $browserTargetUNC = Join-Path $uncRoamingAppData 'Mozilla\Firefox\Profiles'
                }
                'Brave' {
                    $browserTargetUNC = Join-Path $uncLocalAppData 'BraveSoftware\Brave-Browser\User Data'
                }
                default {
                    Write-MigrationLog -Message "Unknown browser '$($browser.BrowserName)', skipping" -Level Warning
                    continue
                }
            }

            if ($browser.SourcePath -and (Test-Path $browser.SourcePath) -and $browserTargetUNC) {
                Write-MigrationLog -Message "Robocopy browser: $($browser.SourcePath) -> $browserTargetUNC" -Level Info

                if (-not (Test-Path $browserTargetUNC)) {
                    New-Item -Path $browserTargetUNC -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }

                $robocopyArgs = @(
                    "`"$($browser.SourcePath)`""
                    "`"$browserTargetUNC`""
                    '/E'
                    "/R:$retries"
                    "/W:$waitSec"
                    "/MT:$threads"
                    '/NP'
                    '/NDL'
                    '/NJH'
                    '/NJS'
                    '/XJ'
                    '/XF', 'Cookies', 'Cookies-journal', 'Login Data', 'Login Data-journal'
                )

                $null = & robocopy @robocopyArgs 2>&1
                $exitCode = $LASTEXITCODE

                if ($exitCode -lt 8) {
                    $browser.ExportStatus = 'Success'
                    Write-MigrationLog -Message "Browser profile '$($browser.BrowserName)' pushed successfully" -Level Info
                } else {
                    $browser.ExportStatus = 'Failed'
                    $errMsg = "Browser profile '$($browser.BrowserName)' push failed (exit code: $exitCode)"
                    $migrationResult.Errors += $errMsg
                    Write-MigrationLog -Message $errMsg -Level Error
                }
            }
        } catch {
            $errMsg = "Failed to push browser '$($browser.BrowserName)': $($_.Exception.Message)"
            $migrationResult.Errors += $errMsg
            Write-MigrationLog -Message $errMsg -Level Error
        }
    }

    # -------------------------------------------------------------------------
    # 5. Push system settings (PSSession if available, UNC file-copy fallback)
    # -------------------------------------------------------------------------
    Write-MigrationLog -Message "Pushing system settings to target" -Level Info
    & $updateProgress 'Applying Settings' 55 'Configuring system settings on target...'

    $session = $null
    $sessionAvailable = $false
    try {
        $session = New-PSSession -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop
        $sessionAvailable = $true
        Write-MigrationLog -Message "PSSession established to '$ComputerName' for settings push" -Level Info
    } catch {
        Write-MigrationLog -Message "PSSession unavailable (WinRM not enabled on target) - using UNC file-copy fallback for settings" -Level Warning
    }

    # Stage settings files to target via UNC so they can be applied on next login or manually
    $settingsStagingUNC = "\\$ComputerName\C`$\Users\$TargetUserName\Win11Migrator\Settings"
    try {
        if (-not (Test-Path $settingsStagingUNC)) {
            New-Item -Path $settingsStagingUNC -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-MigrationLog -Message "Failed to create settings staging directory: $($_.Exception.Message)" -Level Warning
    }

    if ($State.ContainsKey('SystemSettings')) {
        # WiFi profiles
        $wifiSettings = @($State.SystemSettings | Where-Object { $_.Category -eq 'WiFi' -and $_.Selected })
        foreach ($wifi in $wifiSettings) {
            try {
                if ($wifi.ExportPath -and (Test-Path $wifi.ExportPath)) {
                    if ($sessionAvailable) {
                        # Apply directly via PSSession
                        $xmlContent = Get-Content -Path $wifi.ExportPath -Raw -ErrorAction Stop
                        Invoke-Command -Session $session -ScriptBlock {
                            param($xml, $profileName)
                            $tempFile = [System.IO.Path]::GetTempFileName() + '.xml'
                            $xml | Out-File -FilePath $tempFile -Encoding UTF8 -Force
                            netsh wlan add profile filename="$tempFile" 2>&1 | Out-Null
                            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                        } -ArgumentList $xmlContent, $wifi.Name -ErrorAction Stop
                        $migrationResult.SettingsPushed++
                        Write-MigrationLog -Message "WiFi profile '$($wifi.Name)' applied on target" -Level Info
                    } else {
                        # Copy WiFi XML to staging folder for manual import
                        $wifiStagingDir = Join-Path $settingsStagingUNC 'WiFi'
                        if (-not (Test-Path $wifiStagingDir)) {
                            New-Item -Path $wifiStagingDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                        }
                        Copy-Item -Path $wifi.ExportPath -Destination $wifiStagingDir -Force -ErrorAction Stop
                        $migrationResult.SettingsPushed++
                        Write-MigrationLog -Message "WiFi profile '$($wifi.Name)' copied to target staging folder" -Level Info
                    }
                }
            } catch {
                $errMsg = "Failed to push WiFi profile '$($wifi.Name)': $($_.Exception.Message)"
                $migrationResult.Errors += $errMsg
                Write-MigrationLog -Message $errMsg -Level Warning
            }
        }

        # Environment variables
        $envSettings = @($State.SystemSettings | Where-Object { $_.Category -eq 'EnvironmentVariables' -and $_.Selected })
        foreach ($envSetting in $envSettings) {
            try {
                if ($envSetting.Data) {
                    if ($sessionAvailable) {
                        Invoke-Command -Session $session -ScriptBlock {
                            param($data)
                            foreach ($entry in $data) {
                                [System.Environment]::SetEnvironmentVariable($entry.Name, $entry.Value, $entry.Scope)
                            }
                        } -ArgumentList @(,$envSetting.Data) -ErrorAction Stop
                        $migrationResult.SettingsPushed++
                        Write-MigrationLog -Message "Environment variables applied on target" -Level Info
                    } else {
                        # Export env vars as JSON to staging for manual import
                        $envJson = $envSetting.Data | ConvertTo-Json -Depth 5
                        $envFile = Join-Path $settingsStagingUNC 'EnvironmentVariables.json'
                        $envJson | Out-File -FilePath $envFile -Encoding UTF8 -Force
                        $migrationResult.SettingsPushed++
                        Write-MigrationLog -Message "Environment variables exported to target staging folder" -Level Info
                    }
                }
            } catch {
                $errMsg = "Failed to push environment variables: $($_.Exception.Message)"
                $migrationResult.Errors += $errMsg
                Write-MigrationLog -Message $errMsg -Level Warning
            }
        }

        # Mapped drives
        $driveSettings = @($State.SystemSettings | Where-Object { $_.Category -eq 'MappedDrives' -and $_.Selected })
        foreach ($drive in $driveSettings) {
            try {
                if ($drive.Data) {
                    if ($sessionAvailable) {
                        Invoke-Command -Session $session -ScriptBlock {
                            param($data)
                            foreach ($mapping in $data) {
                                New-PSDrive -Name $mapping.DriveLetter -PSProvider FileSystem -Root $mapping.RemotePath -Persist -ErrorAction SilentlyContinue | Out-Null
                            }
                        } -ArgumentList @(,$drive.Data) -ErrorAction Stop
                        $migrationResult.SettingsPushed++
                        Write-MigrationLog -Message "Mapped drives applied on target" -Level Info
                    } else {
                        # Export drive mappings as JSON to staging for manual import
                        $driveJson = $drive.Data | ConvertTo-Json -Depth 5
                        $driveFile = Join-Path $settingsStagingUNC 'MappedDrives.json'
                        $driveJson | Out-File -FilePath $driveFile -Encoding UTF8 -Force
                        $migrationResult.SettingsPushed++
                        Write-MigrationLog -Message "Mapped drives exported to target staging folder" -Level Info
                    }
                }
            } catch {
                $errMsg = "Failed to push mapped drives: $($_.Exception.Message)"
                $migrationResult.Errors += $errMsg
                Write-MigrationLog -Message $errMsg -Level Warning
            }
        }

        # All other settings (Printers, Screensaver, Personalization, etc.) - copy export files via UNC
        $otherSettings = @($State.SystemSettings | Where-Object {
            $_.Selected -and $_.Category -notin @('WiFi', 'EnvironmentVariables', 'MappedDrives')
        })
        foreach ($setting in $otherSettings) {
            try {
                if ($setting.ExportPath -and (Test-Path $setting.ExportPath)) {
                    $catDir = Join-Path $settingsStagingUNC $setting.Category
                    if (-not (Test-Path $catDir)) {
                        New-Item -Path $catDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    }
                    # If ExportPath is a directory, robocopy it; otherwise copy the file
                    if (Test-Path $setting.ExportPath -PathType Container) {
                        $null = & robocopy "`"$($setting.ExportPath)`"" "`"$catDir`"" /E /R:2 /W:2 /NP /NDL /NJH /NJS 2>&1
                    } else {
                        Copy-Item -Path $setting.ExportPath -Destination $catDir -Force -ErrorAction Stop
                    }
                    $migrationResult.SettingsPushed++
                    Write-MigrationLog -Message "Setting '$($setting.Category)/$($setting.Name)' copied to target" -Level Info
                } elseif ($setting.Data) {
                    # Export data as JSON to staging
                    $catDir = Join-Path $settingsStagingUNC $setting.Category
                    if (-not (Test-Path $catDir)) {
                        New-Item -Path $catDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    }
                    $dataJson = $setting.Data | ConvertTo-Json -Depth 10
                    $safeName = ($setting.Name -replace '[\\/:*?"<>|]', '_')
                    $dataFile = Join-Path $catDir "$safeName.json"
                    $dataJson | Out-File -FilePath $dataFile -Encoding UTF8 -Force
                    $migrationResult.SettingsPushed++
                    Write-MigrationLog -Message "Setting '$($setting.Category)/$($setting.Name)' data exported to target" -Level Info
                }
            } catch {
                $errMsg = "Failed to push setting '$($setting.Category)/$($setting.Name)': $($_.Exception.Message)"
                $migrationResult.Errors += $errMsg
                Write-MigrationLog -Message $errMsg -Level Warning
            }
        }
    }

    # -------------------------------------------------------------------------
    # 6. Trigger remote app installs (requires PSSession)
    # -------------------------------------------------------------------------
    Write-MigrationLog -Message "Triggering remote app installs" -Level Info
    & $updateProgress 'Installing Apps' 65 'Installing applications on target...'

    if ($State.ContainsKey('Apps') -and $sessionAvailable) {
        $selectedApps = @($State.Apps | Where-Object { $_.Selected })
        if ($selectedApps.Count -gt 0) {
            try {
                $appResult = Install-AppsRemotely -Session $session -Apps $selectedApps -Progress $Progress
                $migrationResult.AppsPushed = $appResult.Installed
                Write-MigrationLog -Message "Remote app install complete: $($appResult.Installed) installed, $($appResult.Failed) failed, $($appResult.Skipped) skipped" -Level Info
            } catch {
                $errMsg = "Remote app install failed: $($_.Exception.Message)"
                $migrationResult.Errors += $errMsg
                Write-MigrationLog -Message $errMsg -Level Error
            }
        }
    } elseif ($State.ContainsKey('Apps') -and -not $sessionAvailable) {
        # Write app install list to staging folder so user can run it on target
        $selectedApps = @($State.Apps | Where-Object { $_.Selected })
        if ($selectedApps.Count -gt 0) {
            try {
                $appListDir = "\\$ComputerName\C`$\Users\$TargetUserName\Win11Migrator"
                if (-not (Test-Path $appListDir)) {
                    New-Item -Path $appListDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
                $appData = $selectedApps | ForEach-Object {
                    @{
                        Name          = $_.Name
                        InstallMethod = $_.InstallMethod
                        PackageId     = $_.PackageId
                        DownloadUrl   = $_.DownloadUrl
                    }
                }
                $appJson = $appData | ConvertTo-Json -Depth 5
                $appFile = Join-Path $appListDir 'PendingAppInstalls.json'
                $appJson | Out-File -FilePath $appFile -Encoding UTF8 -Force
                Write-MigrationLog -Message "App install list ($($selectedApps.Count) apps) written to target for deferred installation" -Level Info
            } catch {
                $errMsg = "Failed to write app install list to target: $($_.Exception.Message)"
                $migrationResult.Errors += $errMsg
                Write-MigrationLog -Message $errMsg -Level Warning
            }
        }
    }

    # -------------------------------------------------------------------------
    # 7. Write manifest to target for record-keeping
    # -------------------------------------------------------------------------
    Write-MigrationLog -Message "Writing migration manifest to target" -Level Info
    & $updateProgress 'Finalizing' 90 'Writing migration record to target...'

    try {
        $manifestDir = "\\$ComputerName\C`$\Users\$TargetUserName\Win11Migrator"
        if (-not (Test-Path $manifestDir)) {
            New-Item -Path $manifestDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        if ($State.ContainsKey('Manifest') -and $State.Manifest) {
            $manifestJson = $State.Manifest | ConvertTo-Json -Depth 10
            $manifestFile = Join-Path $manifestDir 'manifest.json'
            $manifestJson | Out-File -FilePath $manifestFile -Encoding UTF8 -Force
            Write-MigrationLog -Message "Migration manifest written to $manifestFile" -Level Info
        }
    } catch {
        $errMsg = "Failed to write manifest to target: $($_.Exception.Message)"
        $migrationResult.Errors += $errMsg
        Write-MigrationLog -Message $errMsg -Level Warning
    }

    # -------------------------------------------------------------------------
    # 8. Deploy Win11Migrator to target and trigger restore
    # -------------------------------------------------------------------------
    Write-MigrationLog -Message "Deploying Win11Migrator tool to target for restore" -Level Info
    & $updateProgress 'Deploying Restore' 92 'Copying Win11Migrator to target...'

    $remoteRestoreLaunched = $false
    $remoteMigratorBase = "\\$ComputerName\C`$\Users\$TargetUserName\Win11Migrator"

    try {
        # Copy Win11Migrator tool to target via UNC
        Copy-MigratorToTarget -TargetBasePath $remoteMigratorBase

        # Determine the package folder name on the target
        $packageName = if ($State.ContainsKey('Manifest') -and $State.Manifest.SourceComputerName) {
            $exportDate = Get-Date -Format 'yyyyMMdd'
            "Win11Migration_$($State.Manifest.SourceComputerName)_$exportDate"
        } else {
            "Win11Migration_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        }

        # Copy the migration data (manifest + settings staging) into a package subfolder
        $remotePackagePath = Join-Path $remoteMigratorBase $packageName
        if (-not (Test-Path $remotePackagePath)) {
            New-Item -Path $remotePackagePath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        # Copy the manifest into the package folder
        $remoteManifest = Join-Path $remoteMigratorBase 'manifest.json'
        if (Test-Path $remoteManifest) {
            Copy-Item $remoteManifest -Destination $remotePackagePath -Force -ErrorAction SilentlyContinue
        }

        # Move the Settings staging directory into the package
        $remoteSettings = Join-Path $remoteMigratorBase 'Settings'
        if (Test-Path $remoteSettings) {
            $pkgSettings = Join-Path $remotePackagePath 'SystemSettings'
            if (-not (Test-Path $pkgSettings)) {
                New-Item -Path $pkgSettings -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
            $null = & robocopy "`"$remoteSettings`"" "`"$pkgSettings`"" /E /R:2 /W:2 /NP /NDL /NJH /NJS 2>&1
        }

        # Generate the restore trigger script on the target
        $localMigratorBase = "C:\Users\$TargetUserName\Win11Migrator"
        $localPackagePath = Join-Path $localMigratorBase $packageName
        $restoreScriptContent = @"
# Auto-generated by Win11Migrator network push
Set-ExecutionPolicy Bypass -Scope Process -Force
`$migratorRoot = Split-Path `$MyInvocation.MyCommand.Path
& (Join-Path `$migratorRoot 'Win11Migrator.ps1') -CLI import -PackagePath '$localPackagePath'
"@
        $restoreScriptPath = Join-Path $remoteMigratorBase 'Restore-Migration.ps1'
        $restoreScriptContent | Out-File -FilePath $restoreScriptPath -Encoding UTF8 -Force
        Write-MigrationLog -Message "Restore trigger script written to target" -Level Info

        # Try to launch the restore on the target
        $localRestoreScript = Join-Path $localMigratorBase 'Restore-Migration.ps1'

        if ($sessionAvailable) {
            # Use existing PSSession to launch restore in background
            try {
                Invoke-Command -Session $session -ScriptBlock {
                    param($scriptPath)
                    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptPath`"" -WindowStyle Normal
                } -ArgumentList $localRestoreScript -ErrorAction Stop
                $remoteRestoreLaunched = $true
                Write-MigrationLog -Message "Restore launched on target via PSSession" -Level Success
            } catch {
                Write-MigrationLog -Message "Could not launch restore via PSSession: $($_.Exception.Message)" -Level Warning
            }
        }

        if (-not $remoteRestoreLaunched) {
            # Try WMI process creation as fallback
            try {
                $processArgs = "powershell.exe -ExecutionPolicy Bypass -File `"$localRestoreScript`""
                $wmiResult = Invoke-WmiMethod -Class Win32_Process -Name Create `
                    -ArgumentList $processArgs `
                    -ComputerName $ComputerName `
                    -Credential $Credential `
                    -ErrorAction Stop
                if ($wmiResult.ReturnValue -eq 0) {
                    $remoteRestoreLaunched = $true
                    Write-MigrationLog -Message "Restore launched on target via WMI (PID: $($wmiResult.ProcessId))" -Level Success
                } else {
                    Write-MigrationLog -Message "WMI process creation returned code $($wmiResult.ReturnValue)" -Level Warning
                }
            } catch {
                Write-MigrationLog -Message "Could not launch restore via WMI: $($_.Exception.Message)" -Level Warning
            }
        }

        if (-not $remoteRestoreLaunched) {
            Write-MigrationLog -Message "Could not launch restore remotely. Please run Win11Migrator.bat on the target machine ($ComputerName) to complete the import." -Level Warning
        }
    } catch {
        $errMsg = "Failed to deploy Win11Migrator to target: $($_.Exception.Message)"
        $migrationResult.Errors += $errMsg
        Write-MigrationLog -Message $errMsg -Level Warning
    }

    # Store the remote restore status for the CompletionPage
    $migrationResult.RemoteRestoreLaunched = $remoteRestoreLaunched

    # -------------------------------------------------------------------------
    # Cleanup
    # -------------------------------------------------------------------------
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
    Remove-PSDrive -Name $netDriveName -Force -ErrorAction SilentlyContinue

    # Determine overall success
    $migrationResult.Success = ($migrationResult.Errors.Count -eq 0) -or
        ($migrationResult.UserDataPushed -gt 0 -or $migrationResult.AppsPushed -gt 0 -or $migrationResult.SettingsPushed -gt 0)

    & $updateProgress 'Complete' 100 'Migration push complete.'

    $totalPushed = $migrationResult.UserDataPushed + $migrationResult.AppsPushed + $migrationResult.SettingsPushed
    Write-MigrationLog -Message "Direct push migration complete: $totalPushed items pushed, $($migrationResult.Errors.Count) error(s)" -Level Info

    return $migrationResult
}
