<#
========================================================================================================
    Title:          Win11Migrator - Power Settings Importer
    Filename:       Import-PowerSettings.ps1
    Description:    Restores the Windows power plan on the target machine.
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
    Restores the Windows power plan on the target machine.
.DESCRIPTION
    Reads the exported power plan (.pow file) from the migration package and
    imports it via powercfg /import, then sets it as the active scheme via
    powercfg /setactive. Returns updated [SystemSetting[]] with ImportStatus.
.OUTPUTS
    [SystemSetting[]]
#>

function Import-PowerSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [SystemSetting[]]$Settings
    )

    Write-MigrationLog -Message "Starting power settings import" -Level Info

    $powerDir = Join-Path $PackagePath "PowerSettings"
    if (-not (Test-Path $powerDir)) {
        Write-MigrationLog -Message "PowerSettings directory not found at $powerDir" -Level Warning
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
            Write-MigrationLog -Message "Skipping power setting '$($setting.Name)' (not selected)" -Level Debug
            continue
        }

        switch ($setting.Name) {

            'ActivePowerPlan' {
                try {
                    $exportedFile = $setting.Data['ExportedFile']
                    $schemeName   = $setting.Data['SchemeName']
                    $sourceGuid   = $setting.Data['SchemeGuid']

                    if (-not $exportedFile) {
                        throw "No exported power plan file available"
                    }

                    $powFile = Join-Path $powerDir $exportedFile
                    if (-not (Test-Path $powFile)) {
                        throw "Power plan file not found: $exportedFile"
                    }

                    # Generate a new GUID for the imported plan to avoid conflicts
                    $newGuid = [guid]::NewGuid().ToString()

                    # Import the power plan
                    Write-MigrationLog -Message "Importing power plan '$schemeName' from $exportedFile" -Level Debug
                    $importOutput = & powercfg /import $powFile $newGuid 2>&1
                    $importString = [string]$importOutput

                    # Verify the import succeeded by checking if the GUID is now listed
                    $verifyOutput = & powercfg /list 2>&1
                    $planFound = $false
                    foreach ($line in $verifyOutput) {
                        if ([string]$line -match [regex]::Escape($newGuid)) {
                            $planFound = $true
                            break
                        }
                    }

                    if (-not $planFound) {
                        # Try import without specifying a GUID (let Windows assign one)
                        Write-MigrationLog -Message "Import with explicit GUID may have failed, retrying without GUID" -Level Debug
                        $importOutput2 = & powercfg /import $powFile 2>&1
                        $importString2 = [string]$importOutput2

                        # Parse the assigned GUID from the output
                        if ($importString2 -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                            $newGuid = $Matches[1]
                            $planFound = $true
                        }
                    }

                    if ($planFound) {
                        # Set the imported plan as active
                        Write-MigrationLog -Message "Setting imported power plan as active (GUID: $newGuid)" -Level Debug
                        $setActiveOutput = & powercfg /setactive $newGuid 2>&1

                        # Verify active scheme
                        $activeOutput = & powercfg /getactivescheme 2>&1
                        $activeString = [string]$activeOutput
                        $isNowActive = $activeString -match [regex]::Escape($newGuid)

                        $setting.ImportStatus = 'Success'
                        if (-not $setting.Data) { $setting.Data = @{} }
                        $setting.Data['ImportedGuid'] = $newGuid
                        $setting.Data['IsActive']     = $isNowActive
                        $setting.Data['ImportNote']    = "Power plan '$schemeName' imported and $(if ($isNowActive) { 'set as active' } else { 'imported but may not be active -- verify in Power Options' })"

                        Write-MigrationLog -Message "Power plan '$schemeName' imported successfully (Active=$isNowActive)" -Level Info
                    }
                    else {
                        throw "Power plan import could not be verified. powercfg output: $importString"
                    }
                }
                catch {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = $_.Exception.Message
                    Write-MigrationLog -Message "Failed to import power plan: $($_.Exception.Message)" -Level Error
                }
            }

            'AvailableSchemes' {
                # Informational only -- no import action needed
                $setting.ImportStatus = 'Skipped'
                if (-not $setting.Data) { $setting.Data = @{} }
                $setting.Data['ImportNote'] = 'Informational only -- available schemes listing does not require import'
                Write-MigrationLog -Message "AvailableSchemes is informational only, no import action needed" -Level Debug
            }

            default {
                $setting.ImportStatus = 'Skipped'
                if (-not $setting.Data) { $setting.Data = @{} }
                $setting.Data['ImportNote'] = "Unknown power setting type: $($setting.Name)"
                Write-MigrationLog -Message "Unknown power setting '$($setting.Name)' -- skipping" -Level Warning
            }
        }
    }

    $successCount = ($Settings | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Power settings import complete: $successCount/$($Settings.Count) succeeded" -Level Success

    return $Settings
}
