<#
========================================================================================================
    Title:          Win11Migrator - Printer Configuration Importer
    Filename:       Import-PrinterConfigs.ps1
    Description:    Restores printer configurations and attempts driver installation on the target machine.
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
    Imports printer configurations from the migration manifest onto the target machine.
.DESCRIPTION
    Reads printer settings from the manifest and attempts to recreate each printer.
    Network printers are reconnected via Add-Printer -ConnectionName.
    Local printers are reconstructed with Add-PrinterPort / Add-Printer if the
    driver is available; otherwise a manual-install warning is logged.
.OUTPUTS
    [SystemSetting[]]
#>

function Import-PrinterConfigs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [SystemSetting[]]$Settings
    )

    Write-MigrationLog -Message "Starting printer configuration import" -Level Info

    # Gather existing printers and ports to avoid duplicates
    $existingPrinters = @{}
    try {
        Get-Printer -ErrorAction SilentlyContinue | ForEach-Object { $existingPrinters[$_.Name] = $true }
    }
    catch {
        Write-MigrationLog -Message "Could not enumerate existing printers: $($_.Exception.Message)" -Level Warning
    }

    $existingPorts = @{}
    try {
        Get-PrinterPort -ErrorAction SilentlyContinue | ForEach-Object { $existingPorts[$_.Name] = $true }
    }
    catch {
        Write-MigrationLog -Message "Could not enumerate existing printer ports: $($_.Exception.Message)" -Level Warning
    }

    # Gather available drivers
    $availableDrivers = @{}
    try {
        Get-PrinterDriver -ErrorAction SilentlyContinue | ForEach-Object { $availableDrivers[$_.Name] = $true }
    }
    catch {
        Write-MigrationLog -Message "Could not enumerate printer drivers: $($_.Exception.Message)" -Level Warning
    }

    foreach ($setting in $Settings) {
        if (-not $setting.Selected) {
            $setting.ImportStatus = 'Skipped'
            Write-MigrationLog -Message "Skipping printer '$($setting.Name)' (not selected)" -Level Debug
            continue
        }

        try {
            $printerName  = $setting.Name
            $data         = $setting.Data
            $printerType  = if ($data -and $data['PrinterType']) { $data['PrinterType'] } else { 'Local' }
            $driverName   = if ($data) { $data['DriverName'] } else { $null }
            $portName     = if ($data) { $data['PortName'] } else { $null }

            # Skip if already present on target
            if ($existingPrinters.ContainsKey($printerName)) {
                $setting.ImportStatus = 'Skipped'
                if (-not $setting.Data) { $setting.Data = @{} }
                $setting.Data['ImportNote'] = 'Printer already exists on target'
                Write-MigrationLog -Message "Printer '$printerName' already exists on target -- skipping" -Level Info
                continue
            }

            if ($printerType -eq 'Network') {
                # Network printer: reconnect by UNC path
                $uncPath = $null
                if ($portName -and $portName -match '^\\\\') {
                    $uncPath = $portName
                }
                elseif ($data -and $data['PrinterHostAddress']) {
                    $uncPath = "\\$($data['PrinterHostAddress'])\$printerName"
                }

                if ($uncPath) {
                    Write-MigrationLog -Message "Reconnecting network printer '$printerName' via $uncPath" -Level Info
                    Add-Printer -ConnectionName $uncPath -ErrorAction Stop
                    $setting.ImportStatus = 'Success'
                    Write-MigrationLog -Message "Network printer '$printerName' reconnected" -Level Debug
                }
                else {
                    throw "Unable to determine UNC path for network printer '$printerName'"
                }
            }
            else {
                # Local printer: need driver + port
                if (-not $driverName) {
                    throw "No driver name recorded for local printer '$printerName'"
                }

                if (-not $availableDrivers.ContainsKey($driverName)) {
                    $setting.ImportStatus = 'Failed'
                    if (-not $setting.Data) { $setting.Data = @{} }
                    $setting.Data['ImportError'] = "Driver '$driverName' is not installed on the target machine"
                    $setting.Data['ManualInstallRequired'] = $true
                    Write-MigrationLog -Message "Driver '$driverName' not available for printer '$printerName'. Manual installation required." -Level Warning
                    continue
                }

                # Create port if it does not exist
                if ($portName -and -not $existingPorts.ContainsKey($portName)) {
                    $hostAddress = if ($data -and $data['PrinterHostAddress']) { $data['PrinterHostAddress'] } else { $null }
                    if ($hostAddress) {
                        Write-MigrationLog -Message "Creating TCP/IP printer port '$portName' -> $hostAddress" -Level Debug
                        Add-PrinterPort -Name $portName -PrinterHostAddress $hostAddress -ErrorAction Stop
                    }
                    else {
                        # Attempt to create as a local port
                        Write-MigrationLog -Message "Creating local printer port '$portName'" -Level Debug
                        Add-PrinterPort -Name $portName -ErrorAction Stop
                    }
                }

                # Add the printer
                $addParams = @{
                    Name       = $printerName
                    DriverName = $driverName
                    PortName   = $portName
                }

                if ($data -and $data['Shared'] -eq $true) {
                    $addParams['Shared'] = $true
                    if ($data['ShareName']) {
                        $addParams['ShareName'] = $data['ShareName']
                    }
                }

                Add-Printer @addParams -ErrorAction Stop
                $setting.ImportStatus = 'Success'
                Write-MigrationLog -Message "Local printer '$printerName' created with driver '$driverName'" -Level Debug
            }

            # Restore default printer if it was default on source
            if ($setting.ImportStatus -eq 'Success' -and $data -and $data['IsDefault'] -eq $true) {
                try {
                    $cimPrinter = Get-CimInstance -ClassName Win32_Printer -Filter "Name='$($printerName -replace "'","''")'" -ErrorAction Stop
                    Invoke-CimMethod -InputObject $cimPrinter -MethodName SetDefaultPrinter -ErrorAction Stop | Out-Null
                    Write-MigrationLog -Message "Set '$printerName' as default printer" -Level Debug
                }
                catch {
                    Write-MigrationLog -Message "Could not set '$printerName' as default: $($_.Exception.Message)" -Level Warning
                }
            }
        }
        catch {
            $setting.ImportStatus = 'Failed'
            if (-not $setting.Data) { $setting.Data = @{} }
            $setting.Data['ImportError'] = $_.Exception.Message
            Write-MigrationLog -Message "Failed to import printer '$($setting.Name)': $($_.Exception.Message)" -Level Error
        }
    }

    $successCount = ($Settings | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Printer config import complete: $successCount/$($Settings.Count) succeeded" -Level Success

    return $Settings
}
