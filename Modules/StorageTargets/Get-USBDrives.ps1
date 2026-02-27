<#
========================================================================================================
    Title:          Win11Migrator - USB Drive Detector
    Filename:       Get-USBDrives.ps1
    Description:    Detects available USB storage drives with sufficient space for migration packages.
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
    Discovers removable USB drives available for migration package transfer.
.DESCRIPTION
    Uses Win32_LogicalDisk (DriveType=2 for removable) and Win32_DiskDrive
    WMI queries to enumerate USB and removable storage devices. Returns
    drive letter, label, total size, and free space for each qualifying drive.
.OUTPUTS
    [PSCustomObject[]] Array of objects with DriveLetter, Label, TotalSizeGB,
    FreeSpaceGB, and FileSystem properties.
#>

function Get-USBDrives {
    [CmdletBinding()]
    param()

    Write-MigrationLog -Message "Scanning for removable USB drives..." -Level Info

    $usbDrives = @()
    $foundLetters = @{}

    try {
        # Method 1: All removable drives (DriveType=2) - catches most USB flash drives
        $removableDisks = Get-WmiObject -Class Win32_LogicalDisk -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DriveType -eq 2 -and
                $_.DeviceID -ne 'A:' -and $_.DeviceID -ne 'B:' -and
                $_.Size -gt 0
            }

        foreach ($disk in $removableDisks) {
            $driveLetter = $disk.DeviceID
            if ($foundLetters[$driveLetter]) { continue }
            $foundLetters[$driveLetter] = $true

            $totalGB = [math]::Round($disk.Size / 1GB, 2)
            $freeGB  = [math]::Round($disk.FreeSpace / 1GB, 2)
            $label   = if ($disk.VolumeName) { $disk.VolumeName } else { 'Removable Disk' }

            $usbDrives += [PSCustomObject]@{
                DriveLetter    = $driveLetter
                Label          = $label
                TotalSizeGB    = $totalGB
                FreeGB         = $freeGB
                FreeSpaceBytes = [long]$disk.FreeSpace
                FileSystem     = $disk.FileSystem
                DiskModel      = 'Removable'
            }
            Write-MigrationLog -Message "Found removable drive: $driveLetter ($label) - $freeGB GB free" -Level Info
        }

        # Method 2: USB-connected fixed disks (DriveType=3 on USB interface)
        # Catches USB hard drives and some USB flash drives that report as fixed
        $usbPhysicalDisks = Get-WmiObject -Class Win32_DiskDrive -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceType -eq 'USB' }

        foreach ($physDisk in $usbPhysicalDisks) {
            $escapedId = $physDisk.DeviceID.Replace('\', '\\')
            $partitions = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID='$escapedId'} WHERE AssocClass=Win32_DiskDriveToDiskPartition" -ErrorAction SilentlyContinue

            foreach ($partition in $partitions) {
                $logicalDisks = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($partition.DeviceID)'} WHERE AssocClass=Win32_LogicalDiskToPartition" -ErrorAction SilentlyContinue

                foreach ($logicalDisk in $logicalDisks) {
                    $driveLetter = $logicalDisk.DeviceID
                    if ($foundLetters[$driveLetter]) { continue }
                    if ($driveLetter -eq $env:SystemDrive) { continue }
                    $foundLetters[$driveLetter] = $true

                    $totalGB = [math]::Round($logicalDisk.Size / 1GB, 2)
                    $freeGB  = [math]::Round($logicalDisk.FreeSpace / 1GB, 2)
                    $label   = if ($logicalDisk.VolumeName) { $logicalDisk.VolumeName } else { 'USB Disk' }

                    $usbDrives += [PSCustomObject]@{
                        DriveLetter    = $driveLetter
                        Label          = $label
                        TotalSizeGB    = $totalGB
                        FreeGB         = $freeGB
                        FreeSpaceBytes = [long]$logicalDisk.FreeSpace
                        FileSystem     = $logicalDisk.FileSystem
                        DiskModel      = $physDisk.Model
                    }
                    Write-MigrationLog -Message "Found USB disk: $driveLetter ($label) - $freeGB GB free [$($physDisk.Model)]" -Level Info
                }
            }
        }

        # Method 3: Fallback - any non-system, non-network drive that isn't C:
        # DriveType 3 = Local Disk, check if it's not the system drive
        if ($usbDrives.Count -eq 0) {
            Write-MigrationLog -Message "No USB drives found via standard methods, trying fallback..." -Level Info
            $allLocal = Get-WmiObject -Class Win32_LogicalDisk -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.DriveType -in @(2, 3) -and
                    $_.DeviceID -ne $env:SystemDrive -and
                    $_.DeviceID -ne 'A:' -and $_.DeviceID -ne 'B:' -and
                    $_.Size -gt 0
                }

            foreach ($disk in $allLocal) {
                $driveLetter = $disk.DeviceID
                if ($foundLetters[$driveLetter]) { continue }
                $foundLetters[$driveLetter] = $true

                $totalGB = [math]::Round($disk.Size / 1GB, 2)
                $freeGB  = [math]::Round($disk.FreeSpace / 1GB, 2)
                $label   = if ($disk.VolumeName) { $disk.VolumeName } else { 'External Disk' }

                $usbDrives += [PSCustomObject]@{
                    DriveLetter    = $driveLetter
                    Label          = $label
                    TotalSizeGB    = $totalGB
                    FreeGB         = $freeGB
                    FreeSpaceBytes = [long]$disk.FreeSpace
                    FileSystem     = $disk.FileSystem
                    DiskModel      = 'Unknown'
                }
                Write-MigrationLog -Message "Found external drive (fallback): $driveLetter ($label) - $freeGB GB free" -Level Info
            }
        }
    }
    catch {
        Write-MigrationLog -Message "Error scanning USB drives: $($_.Exception.Message)" -Level Error
        Write-Host "[USB] Error: $($_.Exception.Message)" -ForegroundColor Red
    }

    if ($usbDrives.Count -eq 0) {
        Write-MigrationLog -Message "No suitable USB drives found" -Level Warning
    } else {
        Write-MigrationLog -Message "Found $($usbDrives.Count) USB drive(s)" -Level Success
    }

    return $usbDrives
}
