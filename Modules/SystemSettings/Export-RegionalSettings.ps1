<#
========================================================================================================
    Title:          Win11Migrator - Regional Settings Exporter
    Filename:       Export-RegionalSettings.ps1
    Description:    Exports Windows regional, locale, and keyboard layout settings for migration.
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
    Exports Windows regional and language settings.
.DESCRIPTION
    Reads regional configuration from HKCU:\Control Panel\International,
    captures the user language list, system locale, culture information,
    and keyboard layout preload settings. Returns [SystemSetting[]] with
    Category='Regional'.
.OUTPUTS
    [SystemSetting[]]
#>

function Export-RegionalSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    Write-MigrationLog -Message "Starting regional settings export" -Level Info

    [SystemSetting[]]$results = @()

    # Ensure the output directory exists
    $regionalDir = Join-Path $ExportPath "RegionalSettings"
    if (-not (Test-Path $regionalDir)) {
        New-Item -Path $regionalDir -ItemType Directory -Force | Out-Null
    }

    # ----------------------------------------------------------------
    # 1. International registry settings
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting International registry settings" -Level Debug

        $intlPath = 'HKCU:\Control Panel\International'
        $intlData = @{}

        if (Test-Path $intlPath) {
            $props = Get-ItemProperty -Path $intlPath -ErrorAction SilentlyContinue
            if ($props) {
                # Capture all known International values
                $intlValueNames = @(
                    'sCountry', 'sLanguage', 'LocaleName', 'sShortDate', 'sLongDate',
                    'sShortTime', 'sTimeFormat', 'sDecimal', 'sThousand', 'iNegNumber',
                    'iCurrDigits', 'sCurrency', 'iCurrency', 'sDate', 'sTime',
                    'iDate', 'iTime', 'iTLZero', 'iCalendarType', 'iFirstDayOfWeek',
                    'iFirstWeekOfYear', 'sGrouping', 'sMonDecimalSep', 'sMonGrouping',
                    'sMonThousandSep', 'sNativeDigits', 'NumShape', 'iMeasure',
                    'iPaperSize', 'sPositiveSign', 'sNegativeSign', 'sList',
                    'Locale', 'iCountry', 'iDigits', 'iLZero'
                )

                foreach ($valueName in $intlValueNames) {
                    if ($props.PSObject.Properties[$valueName]) {
                        $intlData[$valueName] = $props.$valueName
                    }
                }

                # Also capture any additional values not in the known list
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS' -and -not $intlData.ContainsKey($p.Name)) {
                        $intlData[$p.Name] = $p.Value
                    }
                }
            }
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'Regional'
        $setting.Name         = 'InternationalSettings'
        $setting.Data         = @{
            Values       = $intlData
            RegistryPath = $intlPath
            ValueCount   = $intlData.Count
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported $($intlData.Count) International registry values" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'Regional'
        $setting.Name         = 'InternationalSettings'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export International settings: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 2. Language list and culture info
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting language and culture information" -Level Debug

        $languageData = @{}

        # Get-WinUserLanguageList
        if (Get-Command Get-WinUserLanguageList -ErrorAction SilentlyContinue) {
            try {
                $langList = Get-WinUserLanguageList -ErrorAction Stop
                $languageData['UserLanguageList'] = @()
                foreach ($lang in $langList) {
                    $languageData['UserLanguageList'] += @{
                        LanguageTag  = $lang.LanguageTag
                        Autonym      = $lang.Autonym
                        EnglishName  = $lang.EnglishName
                        InputMethodTips = @($lang.InputMethodTips)
                    }
                }
            }
            catch {
                Write-MigrationLog -Message "Get-WinUserLanguageList failed: $($_.Exception.Message)" -Level Debug
            }
        }

        # Get-WinSystemLocale
        if (Get-Command Get-WinSystemLocale -ErrorAction SilentlyContinue) {
            try {
                $sysLocale = Get-WinSystemLocale -ErrorAction Stop
                $languageData['SystemLocale'] = @{
                    Name        = $sysLocale.Name
                    DisplayName = $sysLocale.DisplayName
                    LCID        = $sysLocale.LCID
                }
            }
            catch {
                Write-MigrationLog -Message "Get-WinSystemLocale failed: $($_.Exception.Message)" -Level Debug
            }
        }

        # Get-Culture
        try {
            $culture = Get-Culture
            $languageData['Culture'] = @{
                Name                  = $culture.Name
                DisplayName           = $culture.DisplayName
                TwoLetterISOLanguage  = $culture.TwoLetterISOLanguageName
                ThreeLetterISOLanguage = $culture.ThreeLetterISOLanguageName
                LCID                  = $culture.LCID
            }
        }
        catch {
            Write-MigrationLog -Message "Get-Culture failed: $($_.Exception.Message)" -Level Debug
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'Regional'
        $setting.Name         = 'LanguageSettings'
        $setting.Data         = $languageData
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported language and culture information" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'Regional'
        $setting.Name         = 'LanguageSettings'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export language settings: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 3. Keyboard layout
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting keyboard layout settings" -Level Debug

        $keyboardData = @{}
        $preloadPath = 'HKCU:\Keyboard Layout\Preload'

        if (Test-Path $preloadPath) {
            $preloadProps = Get-ItemProperty -Path $preloadPath -ErrorAction SilentlyContinue
            $layouts = @{}
            if ($preloadProps) {
                foreach ($p in $preloadProps.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS') {
                        $layouts[$p.Name] = $p.Value
                    }
                }
            }
            $keyboardData['Preload'] = $layouts
        }

        # Also check for substitutes
        $substitutesPath = 'HKCU:\Keyboard Layout\Substitutes'
        if (Test-Path $substitutesPath) {
            $subProps = Get-ItemProperty -Path $substitutesPath -ErrorAction SilentlyContinue
            $substitutes = @{}
            if ($subProps) {
                foreach ($p in $subProps.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS') {
                        $substitutes[$p.Name] = $p.Value
                    }
                }
            }
            $keyboardData['Substitutes'] = $substitutes
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'Regional'
        $setting.Name         = 'KeyboardLayout'
        $setting.Data         = $keyboardData
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported keyboard layout settings" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'Regional'
        $setting.Name         = 'KeyboardLayout'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export keyboard layout: $($_.Exception.Message)" -Level Error
    }

    # Save all regional settings to JSON
    try {
        $allData = @{}
        foreach ($r in $results) {
            $allData[$r.Name] = $r.Data
        }
        $jsonFile = Join-Path $regionalDir "RegionalSettings.json"
        $allData | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
        Write-MigrationLog -Message "Saved regional settings to RegionalSettings.json" -Level Debug
    }
    catch {
        Write-MigrationLog -Message "Failed to save RegionalSettings.json: $($_.Exception.Message)" -Level Warning
    }

    $successCount = ($results | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Regional settings export complete: $successCount/$($results.Count) succeeded" -Level Success

    return $results
}
