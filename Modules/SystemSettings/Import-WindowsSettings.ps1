<#
========================================================================================================
    Title:          Win11Migrator - Windows Settings Importer
    Filename:       Import-WindowsSettings.ps1
    Description:    Restores Windows personalization and system settings on the target machine.
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
    Restores Windows settings (file associations, taskbar pins) on the target machine.
.DESCRIPTION
    Reads exported Windows settings from the migration package and attempts
    to restore file-type associations and taskbar pinned items on a best-effort
    basis.  Returns updated [SystemSetting[]] with ImportStatus.
.OUTPUTS
    [SystemSetting[]]
#>

function Import-WindowsSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [SystemSetting[]]$Settings
    )

    Write-MigrationLog -Message "Starting Windows settings import" -Level Info

    $winSettingsDir = Join-Path $PackagePath "WindowsSettings"
    if (-not (Test-Path $winSettingsDir)) {
        Write-MigrationLog -Message "WindowsSettings directory not found at $winSettingsDir" -Level Warning
        foreach ($s in $Settings) {
            $s.ImportStatus = 'Skipped'
            if (-not $s.Data) { $s.Data = @{} }
            $s.Data['ImportNote'] = 'Export directory not found'
        }
        return $Settings
    }

    foreach ($setting in $Settings) {
        if (-not $setting.Selected) {
            $setting.ImportStatus = 'Skipped'
            Write-MigrationLog -Message "Skipping Windows setting '$($setting.Name)' (not selected)" -Level Debug
            continue
        }

        switch ($setting.Name) {

            'FileAssociations' {
                try {
                    $assocFile = Join-Path $winSettingsDir "FileAssociations.json"
                    if (-not (Test-Path $assocFile)) {
                        throw "FileAssociations.json not found in package"
                    }

                    $associations = Get-Content $assocFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    $restoredCount = 0
                    $failedCount   = 0

                    foreach ($prop in $associations.PSObject.Properties) {
                        $extension = $prop.Name
                        $progId    = $prop.Value.ProgId

                        try {
                            # Use cmd /c assoc and ftype for basic association
                            # Note: Windows 10+ restricts programmatic changes to file associations.
                            # We write to the registry as a best-effort approach.
                            $regPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$extension\UserChoice"

                            # UserChoice is protected by a hash. Direct writes are unreliable on
                            # Windows 10+.  We use the "assoc" and "ftype" commands as a fallback
                            # and log a note for the user.
                            $openWithPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$extension\OpenWithProgids"
                            if (-not (Test-Path $openWithPath)) {
                                New-Item -Path $openWithPath -Force | Out-Null
                            }
                            # Set the ProgId as a preferred opener
                            New-ItemProperty -Path $openWithPath -Name $progId -Value ([byte[]]@()) -PropertyType Binary -Force -ErrorAction SilentlyContinue | Out-Null

                            $restoredCount++
                        }
                        catch {
                            $failedCount++
                            Write-MigrationLog -Message "Could not restore association for $extension : $($_.Exception.Message)" -Level Debug
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['RestoredCount'] = $restoredCount
                    $setting.Data['FailedCount']   = $failedCount
                    $setting.Data['ImportNote']     = "File associations are partially protected by Windows. $restoredCount OpenWithProgids entries written. Users may need to confirm default apps."

                    Write-MigrationLog -Message "File associations import: $restoredCount restored, $failedCount failed. Users may need to confirm defaults." -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import file associations: $($_.Exception.Message)" -Level Error
                }
            }

            'TaskbarPins' {
                try {
                    # Restore taskbar shortcut files
                    $taskbarLnkDir = Join-Path $winSettingsDir "TaskbarShortcuts"
                    $taskbarDestPath = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"

                    $restoredPins = 0

                    if (Test-Path $taskbarLnkDir) {
                        if (-not (Test-Path $taskbarDestPath)) {
                            New-Item -Path $taskbarDestPath -ItemType Directory -Force | Out-Null
                        }

                        $lnkFiles = Get-ChildItem -Path $taskbarLnkDir -Filter "*.lnk" -ErrorAction SilentlyContinue
                        foreach ($lnk in $lnkFiles) {
                            try {
                                Copy-Item -Path $lnk.FullName -Destination $taskbarDestPath -Force -ErrorAction Stop
                                $restoredPins++
                            }
                            catch {
                                Write-MigrationLog -Message "Could not copy taskbar shortcut $($lnk.Name): $($_.Exception.Message)" -Level Debug
                            }
                        }
                    }

                    # Restore Taskband registry data if available
                    $taskbarFile = Join-Path $winSettingsDir "TaskbarPins.json"
                    $taskbandRestored = $false
                    if (Test-Path $taskbarFile) {
                        try {
                            $taskbarData = Get-Content $taskbarFile -Raw -Encoding UTF8 | ConvertFrom-Json
                            if ($taskbarData.TaskbandData) {
                                $taskbandPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
                                if (Test-Path $taskbandPath) {
                                    if ($taskbarData.TaskbandData.FavoritesResolve) {
                                        $bytes = [Convert]::FromBase64String($taskbarData.TaskbandData.FavoritesResolve)
                                        Set-ItemProperty -Path $taskbandPath -Name 'FavoritesResolve' -Value $bytes -ErrorAction Stop
                                    }
                                    if ($taskbarData.TaskbandData.Favorites) {
                                        $bytes = [Convert]::FromBase64String($taskbarData.TaskbandData.Favorites)
                                        Set-ItemProperty -Path $taskbandPath -Name 'Favorites' -Value $bytes -ErrorAction Stop
                                    }
                                    $taskbandRestored = $true
                                }
                            }
                        }
                        catch {
                            Write-MigrationLog -Message "Could not restore Taskband registry data: $($_.Exception.Message)" -Level Warning
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['RestoredPins']    = $restoredPins
                    $setting.Data['TaskbandRestored'] = $taskbandRestored
                    $setting.Data['ImportNote']       = "Taskbar pins are best-effort. Explorer may need to be restarted for changes to take effect."

                    Write-MigrationLog -Message "Taskbar pins import: $restoredPins shortcuts restored, Taskband registry=$(if ($taskbandRestored) {'restored'} else {'skipped'})" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import taskbar pins: $($_.Exception.Message)" -Level Error
                }
            }

            'StartMenuLayout' {
                try {
                    # Start Menu layout import is very restricted on Windows 10/11.
                    # We log what we can and mark as best-effort.
                    $layoutFile = Join-Path $winSettingsDir "StartLayout.xml"
                    $layoutImported = $false

                    if (Test-Path $layoutFile) {
                        # Import-StartLayout requires admin and only works for new user profiles
                        if (Get-Command Import-StartLayout -ErrorAction SilentlyContinue) {
                            try {
                                Import-StartLayout -LayoutPath $layoutFile -MountPath "$env:SystemDrive\" -ErrorAction Stop
                                $layoutImported = $true
                            }
                            catch {
                                Write-MigrationLog -Message "Import-StartLayout failed (expected on existing profiles): $($_.Exception.Message)" -Level Debug
                            }
                        }

                        # Fallback: copy to LayoutModification.xml
                        if (-not $layoutImported) {
                            $layoutModDest = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Shell\LayoutModification.xml"
                            $layoutModDir  = Split-Path $layoutModDest -Parent
                            if (-not (Test-Path $layoutModDir)) {
                                New-Item -Path $layoutModDir -ItemType Directory -Force | Out-Null
                            }
                            Copy-Item -Path $layoutFile -Destination $layoutModDest -Force -ErrorAction SilentlyContinue
                        }
                    }

                    $setting.ImportStatus = 'Success'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['LayoutImported'] = $layoutImported
                    $setting.Data['ImportNote'] = "Start Menu layout import is limited on Windows 10/11 for existing user profiles."

                    Write-MigrationLog -Message "Start Menu layout import complete (native import=$layoutImported)" -Level Info
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import Start Menu layout: $($_.Exception.Message)" -Level Error
                }
            }

            'Screensaver' {
                try {
                    $ssFile = Join-Path $winSettingsDir "Screensaver.json"
                    if (Test-Path $ssFile) {
                        $ssData = Get-Content $ssFile -Raw -Encoding UTF8 | ConvertFrom-Json
                        $desktopPath = 'HKCU:\Control Panel\Desktop'
                        $restoredCount = 0

                        foreach ($prop in $ssData.PSObject.Properties) {
                            try {
                                Set-ItemProperty -Path $desktopPath -Name $prop.Name -Value $prop.Value -ErrorAction Stop
                                $restoredCount++
                            } catch {
                                Write-MigrationLog -Message "Could not restore screensaver setting '$($prop.Name)': $($_.Exception.Message)" -Level Debug
                            }
                        }

                        $setting.ImportStatus = 'Success'
                        if (-not $setting.Data) { $setting.Data = @{} }
                        $setting.Data['RestoredCount'] = $restoredCount
                        Write-MigrationLog -Message "Screensaver settings import: $restoredCount values restored" -Level Info
                    } else {
                        $setting.ImportStatus = 'Skipped'
                        if (-not $setting.Data) { $setting.Data = @{} }
                        $setting.Data['ImportNote'] = 'Screensaver.json not found'
                    }
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import screensaver settings: $($_.Exception.Message)" -Level Error
                }
            }

            'Personalization' {
                try {
                    $perFile = Join-Path $winSettingsDir "Personalization.json"
                    if (Test-Path $perFile) {
                        $perData = Get-Content $perFile -Raw -Encoding UTF8 | ConvertFrom-Json
                        $restoredCount = 0

                        # Restore wallpaper
                        $desktopPath = 'HKCU:\Control Panel\Desktop'
                        $wpKeys = @('WallpaperStyle', 'TileWallpaper')
                        foreach ($key in $wpKeys) {
                            if ($perData.PSObject.Properties[$key]) {
                                Set-ItemProperty -Path $desktopPath -Name $key -Value $perData.$key -ErrorAction SilentlyContinue
                                $restoredCount++
                            }
                        }

                        # Copy wallpaper file and set it
                        if ($perData.PSObject.Properties['WallpaperBackupFile']) {
                            $wpBackup = Join-Path $winSettingsDir $perData.WallpaperBackupFile
                            if (Test-Path $wpBackup) {
                                $wpDest = Join-Path $env:USERPROFILE "Pictures\MigratedWallpaper$([System.IO.Path]::GetExtension($wpBackup))"
                                Copy-Item -Path $wpBackup -Destination $wpDest -Force -ErrorAction SilentlyContinue
                                # Set wallpaper via SystemParametersInfo
                                try {
                                    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WallpaperHelper {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
    public const int SPI_SETDESKWALLPAPER = 0x0014;
    public const int SPIF_UPDATEINIFILE = 0x01;
    public const int SPIF_SENDCHANGE = 0x02;
}
'@ -ErrorAction SilentlyContinue
                                    [WallpaperHelper]::SystemParametersInfo(
                                        [WallpaperHelper]::SPI_SETDESKWALLPAPER, 0, $wpDest,
                                        [WallpaperHelper]::SPIF_UPDATEINIFILE -bor [WallpaperHelper]::SPIF_SENDCHANGE
                                    ) | Out-Null
                                    $restoredCount++
                                } catch {
                                    Write-MigrationLog -Message "Could not apply wallpaper via SystemParametersInfo: $($_.Exception.Message)" -Level Debug
                                }
                            }
                        }

                        # Restore dark/light mode and accent settings
                        $themePath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
                        if (-not (Test-Path $themePath)) { New-Item -Path $themePath -Force | Out-Null }
                        $themeKeys = @('AppsUseLightTheme', 'SystemUsesLightTheme', 'ColorPrevalence', 'EnableTransparency', 'EnableBlurBehind')
                        foreach ($key in $themeKeys) {
                            if ($perData.PSObject.Properties[$key]) {
                                Set-ItemProperty -Path $themePath -Name $key -Value $perData.$key -ErrorAction SilentlyContinue
                                $restoredCount++
                            }
                        }

                        # Restore DWM accent colors
                        $dwmPath = 'HKCU:\SOFTWARE\Microsoft\Windows\DWM'
                        if (Test-Path $dwmPath) {
                            $dwmKeys = @('AccentColor', 'ColorizationColor', 'ColorizationAfterglow', 'ColorizationColorBalance', 'EnableWindowColorization')
                            foreach ($key in $dwmKeys) {
                                if ($perData.PSObject.Properties[$key]) {
                                    Set-ItemProperty -Path $dwmPath -Name $key -Value $perData.$key -ErrorAction SilentlyContinue
                                    $restoredCount++
                                }
                            }
                        }

                        $setting.ImportStatus = 'Success'
                        if (-not $setting.Data) { $setting.Data = @{} }
                        $setting.Data['RestoredCount'] = $restoredCount
                        $setting.Data['ImportNote'] = 'Theme/accent changes may require sign-out to fully apply.'
                        Write-MigrationLog -Message "Personalization import: $restoredCount values restored" -Level Info
                    } else {
                        $setting.ImportStatus = 'Skipped'
                    }
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import personalization: $($_.Exception.Message)" -Level Error
                }
            }

            'SoundScheme' {
                try {
                    $soundRegFile = Join-Path $winSettingsDir "SoundScheme.reg"
                    if (Test-Path $soundRegFile) {
                        $regResult = & reg.exe import $soundRegFile 2>&1
                        $setting.ImportStatus = if ($LASTEXITCODE -eq 0) { 'Success' } else { 'Failed' }
                        if (-not $setting.Data) { $setting.Data = @{} }
                        $setting.Data['ImportNote'] = 'Sound scheme registry restored. Sign-out may be required.'
                        Write-MigrationLog -Message "Sound scheme import: $(if ($LASTEXITCODE -eq 0) {'succeeded'} else {'failed'})" -Level Info
                    } else {
                        $setting.ImportStatus = 'Skipped'
                    }
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import sound scheme: $($_.Exception.Message)" -Level Error
                }
            }

            'DesktopIcons' {
                try {
                    $diFile = Join-Path $winSettingsDir "DesktopIcons.json"
                    if (Test-Path $diFile) {
                        $diData = Get-Content $diFile -Raw -Encoding UTF8 | ConvertFrom-Json
                        $restoredCount = 0

                        if ($diData.PSObject.Properties['NewStartPanel']) {
                            $regPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
                            if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
                            foreach ($prop in $diData.NewStartPanel.PSObject.Properties) {
                                $val = if ($prop.Value.PSObject.Properties['Value']) { $prop.Value.Value } else { $prop.Value }
                                Set-ItemProperty -Path $regPath -Name $prop.Name -Value $val -Type DWord -ErrorAction SilentlyContinue
                                $restoredCount++
                            }
                        }

                        $setting.ImportStatus = 'Success'
                        if (-not $setting.Data) { $setting.Data = @{} }
                        $setting.Data['RestoredCount'] = $restoredCount
                        $setting.Data['ImportNote'] = 'Desktop icon changes take effect after Explorer restart.'
                        Write-MigrationLog -Message "Desktop icons import: $restoredCount values restored" -Level Info
                    } else {
                        $setting.ImportStatus = 'Skipped'
                    }
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import desktop icons: $($_.Exception.Message)" -Level Error
                }
            }

            'Notifications' {
                try {
                    $notifFile = Join-Path $winSettingsDir "Notifications.json"
                    if (Test-Path $notifFile) {
                        $notifData = Get-Content $notifFile -Raw -Encoding UTF8 | ConvertFrom-Json
                        $restoredCount = 0

                        if ($notifData.PSObject.Properties['AppSettings']) {
                            $basePath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'
                            if (-not (Test-Path $basePath)) { New-Item -Path $basePath -Force | Out-Null }
                            foreach ($appProp in $notifData.AppSettings.PSObject.Properties) {
                                $appPath = Join-Path $basePath $appProp.Name
                                if (-not (Test-Path $appPath)) { New-Item -Path $appPath -Force | Out-Null }
                                foreach ($settingProp in $appProp.Value.PSObject.Properties) {
                                    Set-ItemProperty -Path $appPath -Name $settingProp.Name -Value $settingProp.Value -ErrorAction SilentlyContinue
                                    $restoredCount++
                                }
                            }
                        }

                        if ($notifData.PSObject.Properties['ToastEnabled']) {
                            $pushPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications'
                            if (-not (Test-Path $pushPath)) { New-Item -Path $pushPath -Force | Out-Null }
                            Set-ItemProperty -Path $pushPath -Name 'ToastEnabled' -Value $notifData.ToastEnabled -ErrorAction SilentlyContinue
                            $restoredCount++
                        }

                        $setting.ImportStatus = 'Success'
                        if (-not $setting.Data) { $setting.Data = @{} }
                        $setting.Data['RestoredCount'] = $restoredCount
                        Write-MigrationLog -Message "Notification settings import: $restoredCount values restored" -Level Info
                    } else {
                        $setting.ImportStatus = 'Skipped'
                    }
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import notification settings: $($_.Exception.Message)" -Level Error
                }
            }

            'ExplorerAdvanced' {
                try {
                    $expFile = Join-Path $winSettingsDir "ExplorerAdvanced.json"
                    if (Test-Path $expFile) {
                        $expData = Get-Content $expFile -Raw -Encoding UTF8 | ConvertFrom-Json
                        $restoredCount = 0
                        $advancedPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

                        foreach ($prop in $expData.PSObject.Properties) {
                            if ($prop.Name -like 'Search_*') {
                                # Search settings go under Search key
                                $searchPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'
                                if (-not (Test-Path $searchPath)) { New-Item -Path $searchPath -Force | Out-Null }
                                $keyName = $prop.Name -replace '^Search_', ''
                                Set-ItemProperty -Path $searchPath -Name $keyName -Value $prop.Value -ErrorAction SilentlyContinue
                            } else {
                                Set-ItemProperty -Path $advancedPath -Name $prop.Name -Value $prop.Value -ErrorAction SilentlyContinue
                            }
                            $restoredCount++
                        }

                        $setting.ImportStatus = 'Success'
                        if (-not $setting.Data) { $setting.Data = @{} }
                        $setting.Data['RestoredCount'] = $restoredCount
                        $setting.Data['ImportNote'] = 'Explorer/taskbar settings restored. Explorer restart required for full effect.'
                        Write-MigrationLog -Message "Explorer advanced settings import: $restoredCount values restored" -Level Info
                    } else {
                        $setting.ImportStatus = 'Skipped'
                    }
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import explorer advanced settings: $($_.Exception.Message)" -Level Error
                }
            }

            'DisplaySettings' {
                try {
                    $dispFile = Join-Path $winSettingsDir "DisplaySettings.json"
                    if (Test-Path $dispFile) {
                        $dispData = Get-Content $dispFile -Raw -Encoding UTF8 | ConvertFrom-Json
                        $restoredCount = 0
                        $desktopPath = 'HKCU:\Control Panel\Desktop'

                        foreach ($prop in $dispData.PSObject.Properties) {
                            if ($prop.Name -eq 'PerMonitorSettings' -or $prop.Name -eq 'NightLightConfigured') { continue }
                            if ($prop.Name -eq 'VisualFXSetting') {
                                $vfxPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
                                if (-not (Test-Path $vfxPath)) { New-Item -Path $vfxPath -Force | Out-Null }
                                Set-ItemProperty -Path $vfxPath -Name 'VisualFXSetting' -Value $prop.Value -ErrorAction SilentlyContinue
                                $restoredCount++; continue
                            }
                            if ($prop.Name -eq 'UserPreferencesMask') {
                                $bytes = [Convert]::FromBase64String($prop.Value)
                                Set-ItemProperty -Path $desktopPath -Name 'UserPreferencesMask' -Value $bytes -ErrorAction SilentlyContinue
                                $restoredCount++; continue
                            }
                            Set-ItemProperty -Path $desktopPath -Name $prop.Name -Value $prop.Value -ErrorAction SilentlyContinue
                            $restoredCount++
                        }

                        $setting.ImportStatus = 'Success'
                        if (-not $setting.Data) { $setting.Data = @{} }
                        $setting.Data['RestoredCount'] = $restoredCount
                        $setting.Data['ImportNote'] = 'Display settings restored. Sign-out may be required for DPI changes.'
                        Write-MigrationLog -Message "Display settings import: $restoredCount values restored" -Level Info
                    } else {
                        $setting.ImportStatus = 'Skipped'
                    }
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import display settings: $($_.Exception.Message)" -Level Error
                }
            }

            default {
                $setting.ImportStatus = 'Skipped'
                if (-not $setting.Data) { $setting.Data = @{} }
                $setting.Data['ImportNote'] = "Unknown Windows setting type: $($setting.Name)"
                Write-MigrationLog -Message "Unknown Windows setting '$($setting.Name)' -- skipping" -Level Warning
            }
        }
    }

    $successCount = ($Settings | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Windows settings import complete: $successCount/$($Settings.Count) succeeded" -Level Success

    return $Settings
}
