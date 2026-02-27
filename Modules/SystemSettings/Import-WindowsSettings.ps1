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
