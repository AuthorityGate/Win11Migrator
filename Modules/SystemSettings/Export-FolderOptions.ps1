<#
========================================================================================================
    Title:          Win11Migrator - Folder Options Exporter
    Filename:       Export-FolderOptions.ps1
    Description:    Exports Windows Explorer folder view options and preferences for migration.
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
    Exports Windows Explorer folder options and view settings.
.DESCRIPTION
    Reads folder view preferences from
    HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced,
    including show hidden files, hide file extensions, launch folder windows
    in separate process, and other Explorer behavior settings.
    Returns [SystemSetting[]] with Category='FolderOption'.
.OUTPUTS
    [SystemSetting[]]
#>

function Export-FolderOptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    Write-MigrationLog -Message "Starting folder options export" -Level Info

    [SystemSetting[]]$results = @()

    # Ensure the output directory exists
    $folderDir = Join-Path $ExportPath "FolderOptions"
    if (-not (Test-Path $folderDir)) {
        New-Item -Path $folderDir -ItemType Directory -Force | Out-Null
    }

    # ----------------------------------------------------------------
    # 1. Explorer Advanced settings
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting Explorer Advanced settings" -Level Debug

        $advancedPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        $advancedData = @{}

        if (Test-Path $advancedPath) {
            $props = Get-ItemProperty -Path $advancedPath -ErrorAction SilentlyContinue

            # Known important folder option values
            $knownValues = @(
                'Hidden',              # 1=Show hidden, 2=Don't show
                'HideFileExt',         # 0=Show extensions, 1=Hide
                'ShowSuperHidden',     # 0=Hide protected OS files, 1=Show
                'LaunchTo',            # 1=This PC, 2=Quick Access
                'SeparateProcess',     # 0=No, 1=Yes (separate process for each folder)
                'NavPaneExpandToCurrentFolder',  # 0=No, 1=Yes
                'NavPaneShowAllFolders',         # 0=No, 1=Yes
                'ShowStatusBar',       # 0=Hide, 1=Show
                'ShowCompColor',       # 0=No, 1=Yes (show compressed/encrypted in color)
                'ShowInfoTip',         # 0=No, 1=Show pop-up descriptions
                'ShowTypeOverlay',     # 0=No, 1=Yes
                'TaskbarAnimations',   # 0=No, 1=Yes
                'TaskbarSmallIcons',   # 0=No, 1=Yes
                'TaskbarGlomLevel',    # 0=Always combine, 1=When full, 2=Never
                'MMTaskbarGlomLevel',  # Multi-monitor taskbar grouping
                'Start_TrackDocs',     # 0=No, 1=Track recently opened documents
                'Start_TrackProgs',    # 0=No, 1=Track recently used programs
                'DontUsePowerShellOnWinX',  # 0=PowerShell, 1=Command Prompt
                'AutoCheckSelect',     # 0=No, 1=Use check boxes to select items
                'IconsOnly',           # 0=Show thumbnails, 1=Icons only
                'ListviewAlphaSelect', # 0=No, 1=Translucent selection rectangle
                'ListviewShadow'       # 0=No, 1=Shadow under icon text
            )

            if ($props) {
                # Capture known values first
                foreach ($valueName in $knownValues) {
                    if ($props.PSObject.Properties[$valueName]) {
                        $advancedData[$valueName] = $props.$valueName
                    }
                }

                # Also capture any additional values
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS' -and -not $advancedData.ContainsKey($p.Name)) {
                        $advancedData[$p.Name] = $p.Value
                    }
                }
            }
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'FolderOption'
        $setting.Name         = 'ExplorerAdvanced'
        $setting.Data         = @{
            Values       = $advancedData
            RegistryPath = $advancedPath
            ValueCount   = $advancedData.Count
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported $($advancedData.Count) Explorer Advanced values" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'FolderOption'
        $setting.Name         = 'ExplorerAdvanced'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export Explorer Advanced settings: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 2. Explorer CabinetState (classic folder options)
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting Explorer CabinetState settings" -Level Debug

        $cabinetPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\CabinetState'
        $cabinetData = @{}

        if (Test-Path $cabinetPath) {
            $props = Get-ItemProperty -Path $cabinetPath -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS') {
                        $cabinetData[$p.Name] = $p.Value
                    }
                }
            }
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'FolderOption'
        $setting.Name         = 'CabinetState'
        $setting.Data         = @{
            Values       = $cabinetData
            RegistryPath = $cabinetPath
            ValueCount   = $cabinetData.Count
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported $($cabinetData.Count) CabinetState values" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'FolderOption'
        $setting.Name         = 'CabinetState'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export CabinetState settings: $($_.Exception.Message)" -Level Error
    }

    # Save all folder options to JSON
    try {
        $allData = @{}
        foreach ($r in $results) {
            $allData[$r.Name] = $r.Data
        }
        $jsonFile = Join-Path $folderDir "FolderOptions.json"
        $allData | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
        Write-MigrationLog -Message "Saved folder options to FolderOptions.json" -Level Debug
    }
    catch {
        Write-MigrationLog -Message "Failed to save FolderOptions.json: $($_.Exception.Message)" -Level Warning
    }

    $successCount = ($results | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Folder options export complete: $successCount/$($results.Count) succeeded" -Level Success

    return $results
}
