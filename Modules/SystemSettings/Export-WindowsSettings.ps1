<#
========================================================================================================
    Title:          Win11Migrator - Windows Settings Exporter
    Filename:       Export-WindowsSettings.ps1
    Description:    Exports Windows personalization and system settings (theme, taskbar, etc.) for migration.
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
    Exports file type associations, taskbar pins, and Start Menu layout.
.DESCRIPTION
    Reads file-extension associations from the current user's registry,
    attempts to capture taskbar pinned items, and exports the Start Menu
    layout if available.  Returns [SystemSetting[]] with
    Category='WindowsSetting'.
.OUTPUTS
    [SystemSetting[]]
#>

function Export-WindowsSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    Write-MigrationLog -Message "Starting Windows settings export" -Level Info

    [SystemSetting[]]$results = @()

    # Ensure the output directory exists
    $winSettingsDir = Join-Path $ExportPath "WindowsSettings"
    if (-not (Test-Path $winSettingsDir)) {
        New-Item -Path $winSettingsDir -ItemType Directory -Force | Out-Null
    }

    # ----------------------------------------------------------------
    # 1. File type associations
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting file type associations" -Level Info

        $fileExtsPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
        if (Test-Path $fileExtsPath) {
            $extensions = Get-ChildItem -Path $fileExtsPath -ErrorAction SilentlyContinue

            $associations = @{}
            $exportedCount = 0

            foreach ($extKey in $extensions) {
                $extension = $extKey.PSChildName  # e.g. ".txt"

                try {
                    # UserChoice sub-key holds the current association
                    $userChoicePath = Join-Path $extKey.PSPath 'UserChoice'
                    if (Test-Path $userChoicePath) {
                        $userChoice = Get-ItemProperty -Path $userChoicePath -ErrorAction SilentlyContinue
                        if ($userChoice -and $userChoice.PSObject.Properties['ProgId']) {
                            $associations[$extension] = @{
                                ProgId = $userChoice.ProgId
                                Hash   = if ($userChoice.PSObject.Properties['Hash']) { $userChoice.Hash } else { '' }
                            }
                            $exportedCount++
                        }
                    }
                }
                catch {
                    # Per-item error: log and continue
                    Write-MigrationLog -Message "Could not read association for $extension : $($_.Exception.Message)" -Level Debug
                }
            }

            # Save associations to JSON for the manifest
            $assocFile = Join-Path $winSettingsDir "FileAssociations.json"
            $associations | ConvertTo-Json -Depth 5 | Set-Content -Path $assocFile -Encoding UTF8

            $setting = [SystemSetting]::new()
            $setting.Category     = 'WindowsSetting'
            $setting.Name         = 'FileAssociations'
            $setting.Data         = @{
                Count        = $exportedCount
                ExportedFile = 'FileAssociations.json'
            }
            $setting.ExportStatus = 'Success'
            $results += $setting

            Write-MigrationLog -Message "Exported $exportedCount file type associations" -Level Debug
        }
        else {
            Write-MigrationLog -Message "FileExts registry key not found" -Level Warning
        }
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'WindowsSetting'
        $setting.Name         = 'FileAssociations'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export file associations: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 2. Taskbar pinned items (best effort)
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting taskbar pinned items" -Level Info

        $taskbarPins = @()

        # Method A: Read shortcuts from the taskbar pin folder
        $taskbarPath = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
        if (Test-Path $taskbarPath) {
            $shortcuts = Get-ChildItem -Path $taskbarPath -Filter "*.lnk" -ErrorAction SilentlyContinue

            $shell = New-Object -ComObject WScript.Shell
            foreach ($shortcut in $shortcuts) {
                try {
                    $lnk = $shell.CreateShortcut($shortcut.FullName)
                    $taskbarPins += @{
                        Name             = [System.IO.Path]::GetFileNameWithoutExtension($shortcut.Name)
                        TargetPath       = $lnk.TargetPath
                        Arguments        = $lnk.Arguments
                        WorkingDirectory = $lnk.WorkingDirectory
                        IconLocation     = $lnk.IconLocation
                        ShortcutFile     = $shortcut.Name
                    }
                }
                catch {
                    Write-MigrationLog -Message "Could not read shortcut $($shortcut.Name): $($_.Exception.Message)" -Level Debug
                }
            }

            # Release COM object
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch {}
        }

        # Method B: Check Windows 10/11 taskband registry for additional data
        $taskbandPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
        $taskbandData = @{}
        if (Test-Path $taskbandPath) {
            try {
                $taskbandProps = Get-ItemProperty -Path $taskbandPath -ErrorAction SilentlyContinue
                if ($taskbandProps) {
                    if ($taskbandProps.PSObject.Properties['FavoritesResolve']) {
                        # Binary blob -- store as Base64 for potential restoration
                        $taskbandData['FavoritesResolve'] = [Convert]::ToBase64String($taskbandProps.FavoritesResolve)
                    }
                    if ($taskbandProps.PSObject.Properties['Favorites']) {
                        $taskbandData['Favorites'] = [Convert]::ToBase64String($taskbandProps.Favorites)
                    }
                }
            }
            catch {
                Write-MigrationLog -Message "Could not read Taskband registry: $($_.Exception.Message)" -Level Debug
            }
        }

        # Save taskbar data
        $taskbarExport = @{
            Pins         = $taskbarPins
            TaskbandData = $taskbandData
        }
        $taskbarFile = Join-Path $winSettingsDir "TaskbarPins.json"
        $taskbarExport | ConvertTo-Json -Depth 5 | Set-Content -Path $taskbarFile -Encoding UTF8

        # Copy actual .lnk files for restoration
        if (Test-Path $taskbarPath) {
            $taskbarLnkDir = Join-Path $winSettingsDir "TaskbarShortcuts"
            if (-not (Test-Path $taskbarLnkDir)) {
                New-Item -Path $taskbarLnkDir -ItemType Directory -Force | Out-Null
            }
            Copy-Item -Path (Join-Path $taskbarPath "*.lnk") -Destination $taskbarLnkDir -Force -ErrorAction SilentlyContinue
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'WindowsSetting'
        $setting.Name         = 'TaskbarPins'
        $setting.Data         = @{
            PinCount     = $taskbarPins.Count
            ExportedFile = 'TaskbarPins.json'
            HasTaskband  = ($taskbandData.Count -gt 0)
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported $($taskbarPins.Count) taskbar pinned item(s)" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'WindowsSetting'
        $setting.Name         = 'TaskbarPins'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export taskbar pins: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 3. Start Menu layout
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting Start Menu layout" -Level Info

        $startLayoutExported = $false
        $startLayoutFile = Join-Path $winSettingsDir "StartLayout.xml"

        # Try Export-StartLayout (available on Windows 10/11)
        if (Get-Command Export-StartLayout -ErrorAction SilentlyContinue) {
            try {
                Export-StartLayout -Path $startLayoutFile -ErrorAction Stop
                $startLayoutExported = $true
            }
            catch {
                Write-MigrationLog -Message "Export-StartLayout failed: $($_.Exception.Message)" -Level Debug
            }
        }

        # Fallback: copy the LayoutModification.xml if it exists
        if (-not $startLayoutExported) {
            $layoutModPath = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Shell\LayoutModification.xml"
            if (Test-Path $layoutModPath) {
                Copy-Item -Path $layoutModPath -Destination $startLayoutFile -Force -ErrorAction Stop
                $startLayoutExported = $true
            }
        }

        # Also capture Start Menu shortcuts
        $startMenuPins = @()
        $startMenuPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
        if (Test-Path $startMenuPath) {
            $startShortcuts = Get-ChildItem -Path $startMenuPath -Filter "*.lnk" -Recurse -ErrorAction SilentlyContinue
            foreach ($sc in $startShortcuts) {
                $startMenuPins += @{
                    Name         = [System.IO.Path]::GetFileNameWithoutExtension($sc.Name)
                    RelativePath = $sc.FullName.Substring($startMenuPath.Length).TrimStart('\')
                }
            }
        }

        $startMenuFile = Join-Path $winSettingsDir "StartMenuShortcuts.json"
        $startMenuPins | ConvertTo-Json -Depth 5 | Set-Content -Path $startMenuFile -Encoding UTF8

        $setting = [SystemSetting]::new()
        $setting.Category     = 'WindowsSetting'
        $setting.Name         = 'StartMenuLayout'
        $setting.Data         = @{
            LayoutExported  = $startLayoutExported
            ExportedFile    = if ($startLayoutExported) { 'StartLayout.xml' } else { '' }
            ShortcutCount   = $startMenuPins.Count
            ShortcutsFile   = 'StartMenuShortcuts.json'
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Start Menu layout export complete (Layout=$startLayoutExported, Shortcuts=$($startMenuPins.Count))" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'WindowsSetting'
        $setting.Name         = 'StartMenuLayout'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export Start Menu layout: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 4. Screensaver settings
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting screensaver settings" -Level Info

        $desktopPath = 'HKCU:\Control Panel\Desktop'
        $screensaverData = @{}

        if (Test-Path $desktopPath) {
            $desktopProps = Get-ItemProperty -Path $desktopPath -ErrorAction SilentlyContinue
            if ($desktopProps) {
                $ssKeys = @('ScreenSaveActive', 'ScreenSaveTimeOut', 'SCRNSAVE.EXE', 'ScreenSaverIsSecure')
                foreach ($key in $ssKeys) {
                    if ($desktopProps.PSObject.Properties[$key]) {
                        $screensaverData[$key] = $desktopProps.$key
                    }
                }
            }
        }

        if ($screensaverData.Count -gt 0) {
            $ssFile = Join-Path $winSettingsDir "Screensaver.json"
            $screensaverData | ConvertTo-Json -Depth 3 | Set-Content -Path $ssFile -Encoding UTF8

            $setting = [SystemSetting]::new()
            $setting.Category     = 'WindowsSetting'
            $setting.Name         = 'Screensaver'
            $setting.Data         = @{ Count = $screensaverData.Count; ExportedFile = 'Screensaver.json' }
            $setting.ExportStatus = 'Success'
            $results += $setting
            Write-MigrationLog -Message "Exported screensaver settings ($($screensaverData.Count) values)" -Level Debug
        }
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category = 'WindowsSetting'; $setting.Name = 'Screensaver'
        $setting.Data = @{ Error = $_.Exception.Message }; $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export screensaver settings: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 5. Wallpaper and Theme / Personalization
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting wallpaper and personalization settings" -Level Info

        $personalizeData = @{}

        # Wallpaper path and style from Control Panel\Desktop
        $desktopPath = 'HKCU:\Control Panel\Desktop'
        if (Test-Path $desktopPath) {
            $desktopProps = Get-ItemProperty -Path $desktopPath -ErrorAction SilentlyContinue
            if ($desktopProps) {
                $wpKeys = @('Wallpaper', 'WallpaperStyle', 'TileWallpaper')
                foreach ($key in $wpKeys) {
                    if ($desktopProps.PSObject.Properties[$key]) {
                        $personalizeData[$key] = $desktopProps.$key
                    }
                }
            }
        }

        # Dark/Light mode, accent color, transparency from Themes\Personalize
        $themePath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        if (Test-Path $themePath) {
            $themeProps = Get-ItemProperty -Path $themePath -ErrorAction SilentlyContinue
            if ($themeProps) {
                $themeKeys = @('AppsUseLightTheme', 'SystemUsesLightTheme', 'ColorPrevalence',
                               'EnableTransparency', 'EnableBlurBehind')
                foreach ($key in $themeKeys) {
                    if ($themeProps.PSObject.Properties[$key]) {
                        $personalizeData[$key] = $themeProps.$key
                    }
                }
            }
        }

        # Accent color from DWM
        $dwmPath = 'HKCU:\SOFTWARE\Microsoft\Windows\DWM'
        if (Test-Path $dwmPath) {
            $dwmProps = Get-ItemProperty -Path $dwmPath -ErrorAction SilentlyContinue
            if ($dwmProps) {
                $dwmKeys = @('AccentColor', 'ColorizationColor', 'ColorizationAfterglow',
                             'ColorizationColorBalance', 'EnableWindowColorization')
                foreach ($key in $dwmKeys) {
                    if ($dwmProps.PSObject.Properties[$key]) {
                        $personalizeData[$key] = $dwmProps.$key
                    }
                }
            }
        }

        # Copy wallpaper image file if it exists and is accessible
        $wallpaperCopied = $false
        if ($personalizeData.ContainsKey('Wallpaper') -and -not [string]::IsNullOrWhiteSpace($personalizeData['Wallpaper'])) {
            $wpSource = $personalizeData['Wallpaper']
            if (Test-Path $wpSource) {
                $wpDest = Join-Path $winSettingsDir "WallpaperImage$([System.IO.Path]::GetExtension($wpSource))"
                Copy-Item -Path $wpSource -Destination $wpDest -Force -ErrorAction SilentlyContinue
                $personalizeData['WallpaperBackupFile'] = [System.IO.Path]::GetFileName($wpDest)
                $wallpaperCopied = $true
            }
        }

        # Also copy current theme file if accessible
        $currentThemePath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes'
        if (Test-Path $currentThemePath) {
            $currentTheme = Get-ItemProperty -Path $currentThemePath -ErrorAction SilentlyContinue
            if ($currentTheme -and $currentTheme.PSObject.Properties['CurrentTheme']) {
                $personalizeData['CurrentThemePath'] = $currentTheme.CurrentTheme
                if (Test-Path $currentTheme.CurrentTheme) {
                    Copy-Item -Path $currentTheme.CurrentTheme -Destination (Join-Path $winSettingsDir "CurrentTheme.theme") -Force -ErrorAction SilentlyContinue
                    $personalizeData['ThemeBackupFile'] = 'CurrentTheme.theme'
                }
            }
        }

        if ($personalizeData.Count -gt 0) {
            $perFile = Join-Path $winSettingsDir "Personalization.json"
            $personalizeData | ConvertTo-Json -Depth 3 | Set-Content -Path $perFile -Encoding UTF8

            $setting = [SystemSetting]::new()
            $setting.Category     = 'WindowsSetting'
            $setting.Name         = 'Personalization'
            $setting.Data         = @{ Count = $personalizeData.Count; ExportedFile = 'Personalization.json'; WallpaperCopied = $wallpaperCopied }
            $setting.ExportStatus = 'Success'
            $results += $setting
            Write-MigrationLog -Message "Exported personalization settings ($($personalizeData.Count) values, wallpaper=$wallpaperCopied)" -Level Debug
        }
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category = 'WindowsSetting'; $setting.Name = 'Personalization'
        $setting.Data = @{ Error = $_.Exception.Message }; $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export personalization settings: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 6. Sound scheme and sound events
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting sound scheme" -Level Info

        $soundData = @{}

        # Current sound scheme name
        $schemesPath = 'HKCU:\AppEvents\Schemes'
        if (Test-Path $schemesPath) {
            $schemeProps = Get-ItemProperty -Path $schemesPath -ErrorAction SilentlyContinue
            if ($schemeProps -and $schemeProps.PSObject.Properties['(default)']) {
                $soundData['CurrentScheme'] = $schemeProps.'(default)'
            }
        }

        # Export sound events registry via reg.exe (covers all sub-keys)
        $soundRegFile = Join-Path $winSettingsDir "SoundScheme.reg"
        $regResult = & reg.exe export 'HKCU\AppEvents' $soundRegFile /y 2>&1
        if ($LASTEXITCODE -eq 0) {
            $soundData['RegistryExported'] = $true
            $soundData['RegistryFile'] = 'SoundScheme.reg'
        } else {
            $soundData['RegistryExported'] = $false
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'WindowsSetting'
        $setting.Name         = 'SoundScheme'
        $setting.Data         = $soundData
        $setting.ExportStatus = 'Success'
        $results += $setting
        Write-MigrationLog -Message "Exported sound scheme settings" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category = 'WindowsSetting'; $setting.Name = 'SoundScheme'
        $setting.Data = @{ Error = $_.Exception.Message }; $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export sound scheme: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 7. Desktop icon visibility
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting desktop icon settings" -Level Info

        $desktopIconData = @{}

        # NewStartPanel (Windows 10/11 default)
        $newStartPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
        if (Test-Path $newStartPath) {
            $iconProps = Get-ItemProperty -Path $newStartPath -ErrorAction SilentlyContinue
            if ($iconProps) {
                $desktopIconData['NewStartPanel'] = @{}
                # Known GUIDs: Computer, Network, RecycleBin, UserFiles, ControlPanel
                $knownIcons = @{
                    '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' = 'ThisPC'
                    '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}' = 'Network'
                    '{645FF040-5081-101B-9F08-00AA002F954E}' = 'RecycleBin'
                    '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' = 'UserFiles'
                    '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}' = 'ControlPanel'
                }
                foreach ($prop in $iconProps.PSObject.Properties) {
                    if ($prop.Name -like '{*}') {
                        $friendlyName = if ($knownIcons.ContainsKey($prop.Name)) { $knownIcons[$prop.Name] } else { $prop.Name }
                        $desktopIconData['NewStartPanel'][$prop.Name] = @{
                            Value = $prop.Value
                            Name  = $friendlyName
                        }
                    }
                }
            }
        }

        # ClassicStartMenu (legacy/fallback)
        $classicPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu'
        if (Test-Path $classicPath) {
            $classicProps = Get-ItemProperty -Path $classicPath -ErrorAction SilentlyContinue
            if ($classicProps) {
                $desktopIconData['ClassicStartMenu'] = @{}
                foreach ($prop in $classicProps.PSObject.Properties) {
                    if ($prop.Name -like '{*}') {
                        $desktopIconData['ClassicStartMenu'][$prop.Name] = $prop.Value
                    }
                }
            }
        }

        if ($desktopIconData.Count -gt 0) {
            $diFile = Join-Path $winSettingsDir "DesktopIcons.json"
            $desktopIconData | ConvertTo-Json -Depth 5 | Set-Content -Path $diFile -Encoding UTF8

            $setting = [SystemSetting]::new()
            $setting.Category     = 'WindowsSetting'
            $setting.Name         = 'DesktopIcons'
            $setting.Data         = @{ ExportedFile = 'DesktopIcons.json' }
            $setting.ExportStatus = 'Success'
            $results += $setting
            Write-MigrationLog -Message "Exported desktop icon settings" -Level Debug
        }
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category = 'WindowsSetting'; $setting.Name = 'DesktopIcons'
        $setting.Data = @{ Error = $_.Exception.Message }; $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export desktop icon settings: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 8. Notification and Focus Assist settings
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting notification settings" -Level Info

        $notifData = @{}

        # Per-app notification settings
        $notifPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'
        if (Test-Path $notifPath) {
            $notifApps = Get-ChildItem -Path $notifPath -ErrorAction SilentlyContinue
            $notifData['AppSettings'] = @{}
            foreach ($app in $notifApps) {
                $appProps = Get-ItemProperty -Path $app.PSPath -ErrorAction SilentlyContinue
                if ($appProps) {
                    $appSettings = @{}
                    foreach ($prop in $appProps.PSObject.Properties) {
                        if ($prop.Name -notin @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')) {
                            $appSettings[$prop.Name] = $prop.Value
                        }
                    }
                    $notifData['AppSettings'][$app.PSChildName] = $appSettings
                }
            }
        }

        # Global notification preferences
        $pushNotifPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications'
        if (Test-Path $pushNotifPath) {
            $pushProps = Get-ItemProperty -Path $pushNotifPath -ErrorAction SilentlyContinue
            if ($pushProps) {
                $notifData['ToastEnabled'] = if ($pushProps.PSObject.Properties['ToastEnabled']) { $pushProps.ToastEnabled } else { 1 }
            }
        }

        # Focus Assist / Quiet Hours
        $focusPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.notifications.quiethourssettings'
        if (Test-Path $focusPath) {
            $notifData['FocusAssistConfigured'] = $true
        }

        if ($notifData.Count -gt 0) {
            $notifFile = Join-Path $winSettingsDir "Notifications.json"
            $notifData | ConvertTo-Json -Depth 5 | Set-Content -Path $notifFile -Encoding UTF8

            $setting = [SystemSetting]::new()
            $setting.Category     = 'WindowsSetting'
            $setting.Name         = 'Notifications'
            $setting.Data         = @{ ExportedFile = 'Notifications.json'; AppCount = $notifData['AppSettings'].Count }
            $setting.ExportStatus = 'Success'
            $results += $setting
            Write-MigrationLog -Message "Exported notification settings" -Level Debug
        }
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category = 'WindowsSetting'; $setting.Name = 'Notifications'
        $setting.Data = @{ Error = $_.Exception.Message }; $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export notification settings: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 9. Taskbar and Explorer advanced settings
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting taskbar/explorer advanced settings" -Level Info

        $explorerData = @{}
        $advancedPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        if (Test-Path $advancedPath) {
            $advProps = Get-ItemProperty -Path $advancedPath -ErrorAction SilentlyContinue
            if ($advProps) {
                $advKeys = @(
                    'TaskbarSmallIcons', 'TaskbarGlomLevel', 'ShowTaskViewButton',
                    'TaskbarDa', 'TaskbarMn', 'TaskbarSi', 'TaskbarAl',
                    'ShowCortanaButton', 'SearchboxTaskbarMode',
                    'MMTaskbarEnabled', 'MMTaskbarMode', 'MMTaskbarGlomLevel',
                    'Start_TrackDocs', 'Start_TrackProgs', 'Start_Layout',
                    'ShowStatusBar', 'ShowInfoTip', 'ShowCompColor',
                    'ShowEncryptCompressedColor', 'DontPrettyPath',
                    'MapNetDrvBtn', 'SharingWizardOn',
                    'UseCompactMode', 'EnableSnapAssistFlyout',
                    'SnapAssist', 'DITest', 'EnableSnapBar',
                    'JointResize', 'SnapFill', 'MultiTaskingAltTabFilter'
                )
                foreach ($key in $advKeys) {
                    if ($advProps.PSObject.Properties[$key]) {
                        $explorerData[$key] = $advProps.$key
                    }
                }
            }
        }

        # Search bar settings
        $searchPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'
        if (Test-Path $searchPath) {
            $searchProps = Get-ItemProperty -Path $searchPath -ErrorAction SilentlyContinue
            if ($searchProps) {
                $searchKeys = @('SearchboxTaskbarMode', 'BingSearchEnabled', 'CortanaConsent')
                foreach ($key in $searchKeys) {
                    if ($searchProps.PSObject.Properties[$key]) {
                        $explorerData["Search_$key"] = $searchProps.$key
                    }
                }
            }
        }

        if ($explorerData.Count -gt 0) {
            $expFile = Join-Path $winSettingsDir "ExplorerAdvanced.json"
            $explorerData | ConvertTo-Json -Depth 3 | Set-Content -Path $expFile -Encoding UTF8

            $setting = [SystemSetting]::new()
            $setting.Category     = 'WindowsSetting'
            $setting.Name         = 'ExplorerAdvanced'
            $setting.Data         = @{ Count = $explorerData.Count; ExportedFile = 'ExplorerAdvanced.json' }
            $setting.ExportStatus = 'Success'
            $results += $setting
            Write-MigrationLog -Message "Exported $($explorerData.Count) taskbar/explorer advanced settings" -Level Debug
        }
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category = 'WindowsSetting'; $setting.Name = 'ExplorerAdvanced'
        $setting.Data = @{ Error = $_.Exception.Message }; $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export explorer advanced settings: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 10. Display and DPI settings
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting display settings" -Level Info

        $displayData = @{}

        # DPI scaling from Control Panel\Desktop
        $desktopPath = 'HKCU:\Control Panel\Desktop'
        if (Test-Path $desktopPath) {
            $desktopProps = Get-ItemProperty -Path $desktopPath -ErrorAction SilentlyContinue
            if ($desktopProps) {
                $dispKeys = @('LogPixels', 'Win8DpiScaling', 'DpiScalingVer',
                              'FontSmoothing', 'FontSmoothingType', 'FontSmoothingGamma',
                              'CursorBlinkRate', 'CaretWidth', 'MenuShowDelay')
                foreach ($key in $dispKeys) {
                    if ($desktopProps.PSObject.Properties[$key]) {
                        $displayData[$key] = $desktopProps.$key
                    }
                }
            }
        }

        # Per-monitor DPI settings
        $dpiPath = 'HKCU:\Control Panel\Desktop\PerMonitorSettings'
        if (Test-Path $dpiPath) {
            $monitors = Get-ChildItem -Path $dpiPath -ErrorAction SilentlyContinue
            $displayData['PerMonitorSettings'] = @{}
            foreach ($mon in $monitors) {
                $monProps = Get-ItemProperty -Path $mon.PSPath -ErrorAction SilentlyContinue
                if ($monProps -and $monProps.PSObject.Properties['DpiValue']) {
                    $displayData['PerMonitorSettings'][$mon.PSChildName] = $monProps.DpiValue
                }
            }
        }

        # Night Light settings
        $nightLightPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.settings'
        if (Test-Path $nightLightPath) {
            $displayData['NightLightConfigured'] = $true
        }

        # Visual effects (Performance Options)
        $visualFxPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
        if (Test-Path $visualFxPath) {
            $vfxProps = Get-ItemProperty -Path $visualFxPath -ErrorAction SilentlyContinue
            if ($vfxProps -and $vfxProps.PSObject.Properties['VisualFXSetting']) {
                $displayData['VisualFXSetting'] = $vfxProps.VisualFXSetting
            }
        }

        # UserPreferencesMask (controls visual effects like animations, shadows, etc.)
        if (Test-Path $desktopPath) {
            $desktopProps2 = Get-ItemProperty -Path $desktopPath -ErrorAction SilentlyContinue
            if ($desktopProps2 -and $desktopProps2.PSObject.Properties['UserPreferencesMask']) {
                $displayData['UserPreferencesMask'] = [Convert]::ToBase64String($desktopProps2.UserPreferencesMask)
            }
        }

        if ($displayData.Count -gt 0) {
            $dispFile = Join-Path $winSettingsDir "DisplaySettings.json"
            $displayData | ConvertTo-Json -Depth 5 | Set-Content -Path $dispFile -Encoding UTF8

            $setting = [SystemSetting]::new()
            $setting.Category     = 'WindowsSetting'
            $setting.Name         = 'DisplaySettings'
            $setting.Data         = @{ Count = $displayData.Count; ExportedFile = 'DisplaySettings.json' }
            $setting.ExportStatus = 'Success'
            $results += $setting
            Write-MigrationLog -Message "Exported $($displayData.Count) display/DPI settings" -Level Debug
        }
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category = 'WindowsSetting'; $setting.Name = 'DisplaySettings'
        $setting.Data = @{ Error = $_.Exception.Message }; $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export display settings: $($_.Exception.Message)" -Level Error
    }

    $successCount = ($results | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Windows settings export complete: $successCount/$($results.Count) succeeded" -Level Success

    return $results
}
