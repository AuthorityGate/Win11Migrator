<#
========================================================================================================
    Title:          Win11Migrator - Environment Variable Importer
    Filename:       Import-EnvironmentVariables.ps1
    Description:    Restores user and system environment variables on the target machine.
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
    Restores user-level environment variables on the target machine.
.DESCRIPTION
    Reads environment variable settings from the manifest and restores them
    using [System.Environment]::SetEnvironmentVariable with 'User' scope.
    PATH entries are merged (source entries not already present on the target
    are appended) rather than overwritten.
.OUTPUTS
    [SystemSetting[]]
#>

function Import-EnvironmentVariables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [SystemSetting[]]$Settings
    )

    Write-MigrationLog -Message "Starting environment variable import" -Level Info

    foreach ($setting in $Settings) {
        if (-not $setting.Selected) {
            $setting.ImportStatus = 'Skipped'
            Write-MigrationLog -Message "Skipping environment variable '$($setting.Name)' (not selected)" -Level Debug
            continue
        }

        try {
            $data = $setting.Data
            if (-not $data -or -not $data['VariableName']) {
                throw "No variable name specified in setting data"
            }

            $varName = $data['VariableName']
            $isPath  = if ($data.ContainsKey('IsPath') -and $data['IsPath'] -eq $true) { $true } else { $false }

            if ($isPath) {
                # ---- PATH merging logic ----
                $sourceEntries = @()
                if ($data['PathEntries']) {
                    # Handle both array and string representations
                    if ($data['PathEntries'] -is [array]) {
                        $sourceEntries = $data['PathEntries'] | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
                    }
                    else {
                        $sourceEntries = ($data['PathEntries'] -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
                    }
                }
                elseif ($data['Value']) {
                    $sourceEntries = ($data['Value'] -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
                }

                # Read current target PATH
                $currentPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
                $currentEntries = @()
                if ($currentPath) {
                    $currentEntries = ($currentPath -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
                }

                # Build a case-insensitive lookup of current entries
                $currentLookup = @{}
                foreach ($entry in $currentEntries) {
                    $currentLookup[$entry.ToLowerInvariant()] = $true
                }

                # Merge: add source entries not already on target
                $addedEntries = @()
                foreach ($sourceEntry in $sourceEntries) {
                    if (-not $currentLookup.ContainsKey($sourceEntry.ToLowerInvariant())) {
                        $currentEntries += $sourceEntry
                        $addedEntries += $sourceEntry
                        $currentLookup[$sourceEntry.ToLowerInvariant()] = $true
                    }
                }

                if ($addedEntries.Count -gt 0) {
                    $newPath = ($currentEntries -join ';')
                    [System.Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
                    Write-MigrationLog -Message "Merged $($addedEntries.Count) new PATH entries" -Level Info
                    foreach ($added in $addedEntries) {
                        Write-MigrationLog -Message "  Added PATH entry: $added" -Level Debug
                    }
                }
                else {
                    Write-MigrationLog -Message "All source PATH entries already exist on target. No changes needed." -Level Info
                }

                $setting.ImportStatus = 'Success'
                if (-not $setting.Data) { $setting.Data = @{} }
                $setting.Data['EntriesAdded']   = $addedEntries.Count
                $setting.Data['EntriesSkipped'] = ($sourceEntries.Count - $addedEntries.Count)
                $setting.Data['ImportNote']     = "Merged $($addedEntries.Count) new entries into PATH"
            }
            else {
                # ---- Standard variable restoration ----
                $value = $data['Value']

                # Check if the variable already exists on target
                $existingValue = [System.Environment]::GetEnvironmentVariable($varName, 'User')

                if ($null -ne $existingValue -and $existingValue -eq $value) {
                    $setting.ImportStatus = 'Skipped'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportNote'] = "Variable already exists with same value"
                    Write-MigrationLog -Message "Environment variable '$varName' already has the same value -- skipping" -Level Debug
                    continue
                }

                if ($null -ne $existingValue -and $existingValue -ne $value) {
                    # Variable exists with different value: overwrite but log the old value
                    Write-MigrationLog -Message "Environment variable '$varName' exists with different value. Overwriting (old='$existingValue')" -Level Warning
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['PreviousValue'] = $existingValue
                }

                [System.Environment]::SetEnvironmentVariable($varName, $value, 'User')
                $setting.ImportStatus = 'Success'
                Write-MigrationLog -Message "Restored environment variable: $varName" -Level Debug
            }
        }
        catch {
            $setting.ImportStatus = 'Failed'
            if (-not $setting.Data) { $setting.Data = @{} }
            $setting.Data['ImportError'] = $_.Exception.Message
            Write-MigrationLog -Message "Failed to import environment variable '$($setting.Name)': $($_.Exception.Message)" -Level Error
        }
    }

    $successCount = ($Settings | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Environment variable import complete: $successCount/$($Settings.Count) succeeded" -Level Success

    return $Settings
}
