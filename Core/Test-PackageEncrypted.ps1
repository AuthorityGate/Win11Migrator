<#
========================================================================================================
    Title:          Win11Migrator - Package Encryption Detection
    Filename:       Test-PackageEncrypted.ps1
    Description:    Tests whether a file is a W11MCRYPT encrypted migration package by checking magic bytes.
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
    Checks if a file is an encrypted Win11Migrator package by verifying the W11MCRYPT magic bytes.
.DESCRIPTION
    Reads the first 8 bytes of the specified file and compares them against the
    W11MCRYPT magic byte sequence. Returns $true if the file is an encrypted
    migration package, $false otherwise. Handles missing files, files too small,
    and read errors gracefully.
.OUTPUTS
    [bool]
#>

function Test-PackageEncrypted {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    # Check if file exists
    if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
        Write-MigrationLog -Message "Test-PackageEncrypted: File not found: $FilePath" -Level Debug
        return $false
    }

    try {
        # Check minimum file size (magic 8 + version 4 + salt len 4 = 16 bytes minimum)
        $fileInfo = Get-Item -Path $FilePath -ErrorAction Stop
        if ($fileInfo.Length -lt 16) {
            Write-MigrationLog -Message "Test-PackageEncrypted: File too small to be encrypted package ($($fileInfo.Length) bytes)" -Level Debug
            return $false
        }

        # Read the first 8 bytes and compare against magic
        $stream = [System.IO.File]::OpenRead($FilePath)
        try {
            $header = New-Object byte[] 8
            $bytesRead = $stream.Read($header, 0, 8)

            if ($bytesRead -lt 8) {
                Write-MigrationLog -Message "Test-PackageEncrypted: Could not read 8 header bytes" -Level Debug
                return $false
            }
        } finally {
            $stream.Dispose()
        }

        $expectedMagic = [byte[]]@(0x57, 0x31, 0x31, 0x4D, 0x43, 0x52, 0x50, 0x54)

        for ($i = 0; $i -lt 8; $i++) {
            if ($header[$i] -ne $expectedMagic[$i]) {
                return $false
            }
        }

        Write-MigrationLog -Message "Test-PackageEncrypted: File is a W11MCRYPT encrypted package: $FilePath" -Level Debug
        return $true

    } catch {
        Write-MigrationLog -Message "Test-PackageEncrypted: Error reading file: $($_.Exception.Message)" -Level Warning
        return $false
    }
}
