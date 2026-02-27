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
                if ($taskbandProps.PSObject.Properties['FavoritesResolve']) {
                    # Binary blob -- store as Base64 for potential restoration
                    $taskbandData['FavoritesResolve'] = [Convert]::ToBase64String($taskbandProps.FavoritesResolve)
                }
                if ($taskbandProps.PSObject.Properties['Favorites']) {
                    $taskbandData['Favorites'] = [Convert]::ToBase64String($taskbandProps.Favorites)
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

    $successCount = ($results | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Windows settings export complete: $successCount/$($results.Count) succeeded" -Level Success

    return $results
}
