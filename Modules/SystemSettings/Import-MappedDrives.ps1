<#
========================================================================================================
    Title:          Win11Migrator - Mapped Drive Importer
    Filename:       Import-MappedDrives.ps1
    Description:    Restores mapped network drive configurations on the target machine.
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
    Imports mapped network drives from the migration manifest onto the target machine.
.DESCRIPTION
    Reads mapped drive settings from the manifest and uses "net use" to recreate
    each drive mapping.  Credential prompts are handled gracefully -- a warning
    is logged but the operation does not abort.
.OUTPUTS
    [SystemSetting[]]
#>

function Import-MappedDrives {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [SystemSetting[]]$Settings
    )

    Write-MigrationLog -Message "Starting mapped drive import" -Level Info

    # Gather existing drive mappings to avoid conflicts
    $existingDrives = @{}
    try {
        $netUseOutput = net use 2>&1
        foreach ($line in $netUseOutput) {
            if ($line -match '^\s*\S+\s+([A-Za-z]):') {
                $existingDrives[$Matches[1]] = $true
            }
        }
    }
    catch {
        Write-MigrationLog -Message "Could not enumerate existing drive mappings: $($_.Exception.Message)" -Level Warning
    }

    foreach ($setting in $Settings) {
        if (-not $setting.Selected) {
            $setting.ImportStatus = 'Skipped'
            Write-MigrationLog -Message "Skipping mapped drive '$($setting.Name)' (not selected)" -Level Debug
            continue
        }

        try {
            $data = $setting.Data
            if (-not $data -or -not $data['RemotePath']) {
                throw "No remote path specified for drive '$($setting.Name)'"
            }

            $driveLetter = if ($data['DriveLetter']) { $data['DriveLetter'] } else { $setting.Name }
            $remotePath  = $data['RemotePath']
            $persistent  = if ($data.ContainsKey('Persistent') -and $data['Persistent'] -eq $true) { $true } else { $false }

            # Extract bare letter for comparison
            $bareLetter = ($driveLetter -replace '[:\\]', '').Trim()

            # Check if drive letter is already in use
            if ($existingDrives.ContainsKey($bareLetter)) {
                $setting.ImportStatus = 'Skipped'
                if (-not $setting.Data) { $setting.Data = @{} }
                $setting.Data['ImportNote'] = "Drive letter $driveLetter is already in use on the target"
                Write-MigrationLog -Message "Drive letter $driveLetter is already in use -- skipping" -Level Warning
                continue
            }

            # Build net use command (use argument array to avoid command injection)
            $persistFlag = if ($persistent) { '/PERSISTENT:YES' } else { '/PERSISTENT:NO' }

            Write-MigrationLog -Message "Mapping drive $driveLetter -> $remotePath (Persistent=$persistent)" -Level Info

            $output = & net.exe use $driveLetter $remotePath $persistFlag 2>&1
            if ($LASTEXITCODE -ne 0) {
                # Common failure: credentials required (error 1219, 1326, etc.)
                $errorText = $output -join ' '
                if ($errorText -match '1219|1326|1244|credential|logon|password|access denied') {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = "Credentials required for $remotePath. User must map this drive manually."
                    $setting.Data['ManualActionRequired'] = $true
                    Write-MigrationLog -Message "Drive $driveLetter -> $remotePath requires credentials. Manual mapping needed." -Level Warning
                    continue
                }
                throw "net use returned exit code $LASTEXITCODE : $errorText"
            }

            $setting.ImportStatus = 'Success'
            Write-MigrationLog -Message "Mapped drive $driveLetter -> $remotePath" -Level Debug

            # Mark the letter as used
            $existingDrives[$bareLetter] = $true
        }
        catch {
            $setting.ImportStatus = 'Failed'
            if (-not $setting.Data) { $setting.Data = @{} }
            $setting.Data['ImportError'] = $_.Exception.Message
            Write-MigrationLog -Message "Failed to import mapped drive '$($setting.Name)': $($_.Exception.Message)" -Level Error
        }
    }

    $successCount = ($Settings | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Mapped drive import complete: $successCount/$($Settings.Count) succeeded" -Level Success

    return $Settings
}
