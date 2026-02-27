<#
========================================================================================================
    Title:          Win11Migrator - Cross-OS Settings Converter
    Filename:       Convert-CrossOSSettings.ps1
    Description:    Transforms system settings between Win10 and Win11 for cross-OS migration compatibility.
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
    Converts system settings between Windows 10 and Windows 11 formats.
.DESCRIPTION
    Analyzes the source and target OS contexts and applies necessary transformations
    to system settings. Handles incompatible features like Start Menu layout (tiles vs
    new layout), taskbar alignment defaults, file association hash changes, and default
    app restrictions on Win11. Settings that cannot be translated are marked as skipped
    with an explanation. If source and target are the same OS, settings pass through unchanged.
.PARAMETER SourceOSContext
    Hashtable from Get-OSMigrationContext run on the source machine.
.PARAMETER TargetOSContext
    Hashtable from Get-OSMigrationContext run on the target machine.
.PARAMETER Settings
    Array of SystemSetting objects to transform.
.OUTPUTS
    [hashtable] with keys: Settings ([SystemSetting[]]), Warnings ([string[]]), SkippedSettings ([string[]])
#>

function Convert-CrossOSSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$SourceOSContext,

        [Parameter(Mandatory)]
        [hashtable]$TargetOSContext,

        [Parameter(Mandatory)]
        [SystemSetting[]]$Settings
    )

    Write-MigrationLog -Message "Starting cross-OS settings conversion" -Level Info

    $warnings = @()
    $skippedSettings = @()
    [SystemSetting[]]$convertedSettings = @()

    try {
        $isSameOS = ($SourceOSContext.IsWindows10 -eq $TargetOSContext.IsWindows10) -and
                    ($SourceOSContext.IsWindows11 -eq $TargetOSContext.IsWindows11)

        if ($isSameOS) {
            Write-MigrationLog -Message "Source and target are the same OS version -- no cross-OS conversion needed" -Level Info
            return @{
                Settings        = $Settings
                Warnings        = @()
                SkippedSettings = @()
            }
        }

        $sourceLabel = if ($SourceOSContext.IsWindows11) { "Windows 11" } else { "Windows 10" }
        $targetLabel = if ($TargetOSContext.IsWindows11) { "Windows 11" } else { "Windows 10" }
        Write-MigrationLog -Message "Cross-OS migration detected: $sourceLabel -> $targetLabel" -Level Info

        foreach ($setting in $Settings) {
            try {
                # ----------------------------------------------------------------
                # 1. Start Menu Layout: Win10 tiles XML is incompatible with Win11
                # ----------------------------------------------------------------
                if ($setting.Name -eq 'StartMenuLayout') {
                    if ($SourceOSContext.IsWindows10 -and $TargetOSContext.IsWindows11) {
                        $skippedSettings += $setting.Name
                        $setting.ImportStatus = 'Skipped'
                        if (-not $setting.Data) { $setting.Data = @{} }
                        $setting.Data['SkipReason'] = 'Start Menu layout incompatible across OS versions'
                        Write-MigrationLog -Message "Skipped StartMenuLayout: Win10 tiles are incompatible with Win11 Start Menu" -Level Warning
                        $convertedSettings += $setting
                        continue
                    }
                    if ($SourceOSContext.IsWindows11 -and $TargetOSContext.IsWindows10) {
                        $skippedSettings += $setting.Name
                        $setting.ImportStatus = 'Skipped'
                        if (-not $setting.Data) { $setting.Data = @{} }
                        $setting.Data['SkipReason'] = 'Win11 Start Menu layout cannot be converted to Win10 tiles format'
                        Write-MigrationLog -Message "Skipped StartMenuLayout: Win11 layout cannot be converted to Win10 tiles" -Level Warning
                        $convertedSettings += $setting
                        continue
                    }
                }

                # ----------------------------------------------------------------
                # 2. Taskbar alignment: Win10 is left-aligned by default,
                #    Win11 is center-aligned. Preserve user familiarity.
                # ----------------------------------------------------------------
                if ($setting.Name -eq 'TaskbarPins' -or $setting.Category -eq 'WindowsSetting') {
                    if ($SourceOSContext.IsWindows10 -and $TargetOSContext.IsWindows11) {
                        # Add a note that we will set TaskbarAl=0 to match Win10 left-aligned default
                        if (-not $setting.Data) { $setting.Data = @{} }
                        $setting.Data['TaskbarAlignmentOverride'] = @{
                            RegistryPath  = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                            ValueName     = 'TaskbarAl'
                            ValueData     = 0
                            ValueType     = 'DWord'
                            Reason        = 'Set left-aligned taskbar to match Windows 10 default'
                        }
                        Write-MigrationLog -Message "TaskbarPins: will set TaskbarAl=0 on Win11 target to match Win10 left-aligned default" -Level Info
                    }
                }

                # ----------------------------------------------------------------
                # 3. File Associations: UserChoice hash changed between Win10/Win11
                # ----------------------------------------------------------------
                if ($setting.Name -eq 'FileAssociations') {
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['CrossOSMode'] = 'OpenWithProgidsOnly'
                    $setting.Data['UserChoiceHashValid'] = $false
                    $assocWarning = "File associations require manual confirmation in Settings > Default Apps"
                    $warnings += $assocWarning
                    Write-MigrationLog -Message "FileAssociations: UserChoice hash is invalid across OS versions, using OpenWithProgids only" -Level Warning
                    $convertedSettings += $setting
                    continue
                }

                # ----------------------------------------------------------------
                # 4. Default Apps: Cannot be set programmatically on Win11
                # ----------------------------------------------------------------
                if ($setting.Name -like 'DefaultApp*' -or ($setting.Data -and $setting.Data['IsDefaultApp'])) {
                    if ($TargetOSContext.IsWindows11) {
                        $defaultAppWarning = "Default app '$($setting.Name)' cannot be set programmatically on Windows 11. " +
                                             "The user must set default apps manually via Settings > Default Apps."
                        $warnings += $defaultAppWarning
                        if (-not $setting.Data) { $setting.Data = @{} }
                        $setting.Data['RequiresManualAction'] = $true
                        Write-MigrationLog -Message "Default app setting '$($setting.Name)' requires manual action on Win11" -Level Warning
                    }
                }

                $convertedSettings += $setting
            }
            catch {
                Write-MigrationLog -Message "Error converting setting '$($setting.Name)': $($_.Exception.Message)" -Level Error
                $setting.ImportStatus = 'Failed'
                $convertedSettings += $setting
            }
        }

        # ----------------------------------------------------------------
        # Add a new taskbar alignment setting if migrating Win10 -> Win11
        # and no TaskbarPins setting was already processed
        # ----------------------------------------------------------------
        if ($SourceOSContext.IsWindows10 -and $TargetOSContext.IsWindows11) {
            $hasTaskbarSetting = $convertedSettings | Where-Object {
                $_.Name -eq 'TaskbarPins' -or ($_.Data -and $_.Data['TaskbarAlignmentOverride'])
            }
            if (-not $hasTaskbarSetting) {
                $taskbarSetting = [SystemSetting]::new()
                $taskbarSetting.Category = 'WindowsSetting'
                $taskbarSetting.Name = 'TaskbarAlignment'
                $taskbarSetting.Data = @{
                    RegistryPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                    ValueName    = 'TaskbarAl'
                    ValueData    = 0
                    ValueType    = 'DWord'
                    Reason       = 'Set left-aligned taskbar to match Windows 10 default'
                }
                $taskbarSetting.ExportStatus = 'Success'
                $convertedSettings += $taskbarSetting
                Write-MigrationLog -Message "Added TaskbarAlignment setting to set left-aligned taskbar on Win11 target" -Level Info
            }
        }

        $totalWarnings = $warnings.Count
        $totalSkipped = $skippedSettings.Count
        Write-MigrationLog -Message "Cross-OS conversion complete: $($convertedSettings.Count) settings processed, $totalSkipped skipped, $totalWarnings warning(s)" -Level Success

        return @{
            Settings        = $convertedSettings
            Warnings        = $warnings
            SkippedSettings = $skippedSettings
        }
    }
    catch {
        Write-MigrationLog -Message "Cross-OS settings conversion failed: $($_.Exception.Message)" -Level Error
        throw
    }
}
