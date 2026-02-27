<#
========================================================================================================
    Title:          Win11Migrator - Power Settings Exporter
    Filename:       Export-PowerSettings.ps1
    Description:    Exports the active Windows power plan for migration to a new machine.
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
    Exports the active Windows power plan configuration.
.DESCRIPTION
    Captures the active power scheme via powercfg /getactivescheme, then
    exports the full plan to a .pow file via powercfg /export. Also records
    metadata about the plan name and GUID for restoration on the target
    machine. Returns [SystemSetting[]] with Category='PowerPlan'.
.OUTPUTS
    [SystemSetting[]]
#>

function Export-PowerSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    Write-MigrationLog -Message "Starting power settings export" -Level Info

    [SystemSetting[]]$results = @()

    # Ensure the output directory exists
    $powerDir = Join-Path $ExportPath "PowerSettings"
    if (-not (Test-Path $powerDir)) {
        New-Item -Path $powerDir -ItemType Directory -Force | Out-Null
    }

    # ----------------------------------------------------------------
    # 1. Get active power scheme
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Querying active power scheme" -Level Debug

        $activeSchemeOutput = & powercfg /getactivescheme 2>&1
        $activeSchemeString = [string]$activeSchemeOutput

        # Parse the GUID and name from output like:
        # "Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)"
        $schemeGuid = ''
        $schemeName = ''

        if ($activeSchemeString -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $schemeGuid = $Matches[1]
        }
        if ($activeSchemeString -match '\(([^)]+)\)') {
            $schemeName = $Matches[1]
        }

        if (-not $schemeGuid) {
            throw "Could not parse active power scheme GUID from powercfg output: $activeSchemeString"
        }

        Write-MigrationLog -Message "Active power scheme: $schemeName (GUID: $schemeGuid)" -Level Debug

        # ----------------------------------------------------------------
        # 2. Export the active plan to a .pow file
        # ----------------------------------------------------------------
        $powFile = Join-Path $powerDir "ActivePowerPlan.pow"
        $exportOutput = & powercfg /export $powFile $schemeGuid 2>&1

        $planExported = Test-Path $powFile
        if (-not $planExported) {
            Write-MigrationLog -Message "powercfg /export did not create the .pow file. Output: $exportOutput" -Level Warning
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'PowerPlan'
        $setting.Name         = 'ActivePowerPlan'
        $setting.Data         = @{
            SchemeGuid     = $schemeGuid
            SchemeName     = $schemeName
            ExportedFile   = if ($planExported) { 'ActivePowerPlan.pow' } else { '' }
            PlanExported   = $planExported
            RawOutput      = $activeSchemeString
        }
        $setting.ExportStatus = if ($planExported) { 'Success' } else { 'Failed' }
        $results += $setting

        if ($planExported) {
            Write-MigrationLog -Message "Exported active power plan '$schemeName' to ActivePowerPlan.pow" -Level Debug
        }
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'PowerPlan'
        $setting.Name         = 'ActivePowerPlan'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export active power plan: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 3. List all available power schemes (informational)
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Listing all available power schemes" -Level Debug

        $allSchemesOutput = & powercfg /list 2>&1
        $schemes = @()

        foreach ($line in $allSchemesOutput) {
            $lineStr = [string]$line
            if ($lineStr -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                $guid = $Matches[1]
                $name = ''
                if ($lineStr -match '\(([^)]+)\)') {
                    $name = $Matches[1]
                }
                $isActive = $lineStr -match '\*$'
                $schemes += @{
                    GUID     = $guid
                    Name     = $name
                    IsActive = $isActive
                }
            }
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'PowerPlan'
        $setting.Name         = 'AvailableSchemes'
        $setting.Data         = @{
            Schemes = $schemes
            Count   = $schemes.Count
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Found $($schemes.Count) available power scheme(s)" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'PowerPlan'
        $setting.Name         = 'AvailableSchemes'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to list power schemes: $($_.Exception.Message)" -Level Error
    }

    # Save metadata to JSON
    try {
        $allData = @{}
        foreach ($r in $results) {
            $allData[$r.Name] = $r.Data
        }
        $jsonFile = Join-Path $powerDir "PowerSettings.json"
        $allData | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
        Write-MigrationLog -Message "Saved power settings metadata to PowerSettings.json" -Level Debug
    }
    catch {
        Write-MigrationLog -Message "Failed to save PowerSettings.json: $($_.Exception.Message)" -Level Warning
    }

    $successCount = ($results | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Power settings export complete: $successCount/$($results.Count) succeeded" -Level Success

    return $results
}
