<#
========================================================================================================
    Title:          Win11Migrator - Printer Configuration Exporter
    Filename:       Export-PrinterConfigs.ps1
    Description:    Exports installed printer configurations and driver information for migration.
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
    Exports installed printer configurations from the source machine.
.DESCRIPTION
    Enumerates printers via Get-Printer and captures Name, DriverName,
    PortName, Shared, ShareName, PrinterStatus, and Type.  Also captures
    port details via Get-PrinterPort.  Returns [SystemSetting[]] with
    Category='Printer'.
.OUTPUTS
    [SystemSetting[]]
#>

function Export-PrinterConfigs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    Write-MigrationLog -Message "Starting printer configuration export" -Level Info

    [SystemSetting[]]$results = @()

    # Enumerate printers
    try {
        $printers = Get-Printer -ErrorAction Stop
    }
    catch {
        Write-MigrationLog -Message "Failed to enumerate printers: $($_.Exception.Message)" -Level Error
        return $results
    }

    if (-not $printers -or $printers.Count -eq 0) {
        Write-MigrationLog -Message "No printers found on this system" -Level Info
        return $results
    }

    # Build a port lookup table
    $portLookup = @{}
    try {
        $ports = Get-PrinterPort -ErrorAction SilentlyContinue
        foreach ($port in $ports) {
            $portLookup[$port.Name] = @{
                PortType        = if ($port.PSObject.Properties['Description']) { $port.Description } else { 'Unknown' }
                PrinterHostAddress = if ($port.PSObject.Properties['PrinterHostAddress']) { $port.PrinterHostAddress } else { '' }
                PortNumber      = if ($port.PSObject.Properties['PortNumber']) { $port.PortNumber } else { 0 }
                SNMPEnabled     = if ($port.PSObject.Properties['SNMPEnabled']) { $port.SNMPEnabled } else { $false }
            }
        }
    }
    catch {
        Write-MigrationLog -Message "Failed to enumerate printer ports: $($_.Exception.Message). Continuing without port details." -Level Warning
    }

    Write-MigrationLog -Message "Found $($printers.Count) printer(s) to export" -Level Info

    foreach ($printer in $printers) {
        $setting = [SystemSetting]::new()
        $setting.Category = 'Printer'
        $setting.Name = $printer.Name
        $setting.Data = @{}

        try {
            $setting.Data['DriverName']     = $printer.DriverName
            $setting.Data['PortName']       = $printer.PortName
            $setting.Data['Shared']         = $printer.Shared
            $setting.Data['ShareName']      = $printer.ShareName
            $setting.Data['PrinterStatus']  = $printer.PrinterStatus.ToString()
            $setting.Data['Type']           = $printer.Type.ToString()

            # Determine printer category for import logic
            $printerType = 'Local'
            if ($printer.Type -eq 'Connection' -or ($printer.PortName -and $printer.PortName -match '^\\\\')) {
                $printerType = 'Network'
            }
            $setting.Data['PrinterType'] = $printerType

            # Attach port details if available
            if ($portLookup.ContainsKey($printer.PortName)) {
                $portInfo = $portLookup[$printer.PortName]
                $setting.Data['PortType']            = $portInfo.PortType
                $setting.Data['PrinterHostAddress']  = $portInfo.PrinterHostAddress
                $setting.Data['PortNumber']          = $portInfo.PortNumber
                $setting.Data['SNMPEnabled']         = $portInfo.SNMPEnabled
            }

            # Check if default printer
            try {
                $defaultPrinter = (Get-CimInstance -ClassName Win32_Printer -Filter "Default=True" -ErrorAction SilentlyContinue).Name
                $setting.Data['IsDefault'] = ($printer.Name -eq $defaultPrinter)
            }
            catch {
                $setting.Data['IsDefault'] = $false
            }

            $setting.ExportStatus = 'Success'
            Write-MigrationLog -Message "Exported printer config: $($printer.Name) (Type=$printerType, Driver=$($printer.DriverName))" -Level Debug
        }
        catch {
            $setting.ExportStatus = 'Failed'
            $setting.Data['Error'] = $_.Exception.Message
            Write-MigrationLog -Message "Failed to export printer '$($printer.Name)': $($_.Exception.Message)" -Level Error
        }

        $results += $setting
    }

    $successCount = ($results | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Printer config export complete: $successCount/$($results.Count) succeeded" -Level Success

    return $results
}
