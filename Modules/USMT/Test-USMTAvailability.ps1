<#
========================================================================================================
    Title:          Win11Migrator - USMT Availability Check
    Filename:       Test-USMTAvailability.ps1
    Description:    Detects whether USMT (User State Migration Tool) is installed and locates its binaries.
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
    Checks for USMT installation and returns paths to ScanState, LoadState, and migration XMLs.
.DESCRIPTION
    Searches standard Windows ADK installation directories and the system PATH
    for USMT binaries (scanstate.exe, loadstate.exe). Returns a hashtable with
    availability status, binary paths, version information, architecture, and
    paths to the standard migration XML files.
.OUTPUTS
    [hashtable] with Available, ScanStatePath, LoadStatePath, Version, Architecture,
    MigAppXml, MigDocsXml, and MigUserXml keys.
#>

function Test-USMTAvailability {
    [CmdletBinding()]
    param()

    Write-MigrationLog -Message "Checking for USMT availability..." -Level Info

    $result = @{
        Available     = $false
        ScanStatePath = ''
        LoadStatePath = ''
        Version       = ''
        Architecture  = ''
        MigAppXml     = ''
        MigDocsXml    = ''
        MigUserXml    = ''
    }

    # Standard Windows ADK USMT locations (prefer amd64 over x86)
    $adkBasePaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
        "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
    )

    $architectures = @('amd64', 'x86')
    $scanStatePath = $null
    $loadStatePath = $null
    $usmtDir       = $null
    $arch          = ''

    # Search ADK installation directories
    foreach ($basePath in $adkBasePaths) {
        foreach ($architecture in $architectures) {
            $candidateDir  = Join-Path -Path $basePath -ChildPath $architecture
            $candidateScan = Join-Path -Path $candidateDir -ChildPath 'scanstate.exe'
            $candidateLoad = Join-Path -Path $candidateDir -ChildPath 'loadstate.exe'

            if ((Test-Path -Path $candidateScan) -and (Test-Path -Path $candidateLoad)) {
                $scanStatePath = $candidateScan
                $loadStatePath = $candidateLoad
                $usmtDir       = $candidateDir
                $arch          = $architecture
                Write-MigrationLog -Message "Found USMT in ADK directory: $candidateDir ($architecture)" -Level Debug
                break
            }
        }
        if ($scanStatePath) { break }
    }

    # Fall back to PATH search if not found in ADK locations
    if (-not $scanStatePath) {
        Write-MigrationLog -Message "USMT not found in standard ADK paths, checking PATH..." -Level Debug

        $scanStateCmd = Get-Command -Name 'scanstate.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $loadStateCmd = Get-Command -Name 'loadstate.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($scanStateCmd -and $loadStateCmd) {
            $scanStatePath = $scanStateCmd.Source
            $loadStatePath = $loadStateCmd.Source
            $usmtDir       = Split-Path -Path $scanStatePath -Parent

            # Detect architecture from path
            if ($usmtDir -match 'amd64') {
                $arch = 'amd64'
            } elseif ($usmtDir -match 'x86') {
                $arch = 'x86'
            } else {
                $arch = 'unknown'
            }

            Write-MigrationLog -Message "Found USMT in PATH: $usmtDir" -Level Debug
        }
    }

    # If still not found, return unavailable
    if (-not $scanStatePath) {
        Write-MigrationLog -Message "USMT is not installed or not found on this system" -Level Warning
        return $result
    }

    # Get version information from scanstate.exe
    $version = ''
    try {
        $versionInfo = (Get-Item -Path $scanStatePath).VersionInfo
        $version = $versionInfo.FileVersion
        if (-not $version) {
            $version = "$($versionInfo.FileMajorPart).$($versionInfo.FileMinorPart).$($versionInfo.FileBuildPart).$($versionInfo.FilePrivatePart)"
        }
    } catch {
        Write-MigrationLog -Message "Could not read USMT version: $($_.Exception.Message)" -Level Debug
    }

    # Locate standard migration XML files
    $migAppXml  = Join-Path -Path $usmtDir -ChildPath 'MigApp.xml'
    $migDocsXml = Join-Path -Path $usmtDir -ChildPath 'MigDocs.xml'
    $migUserXml = Join-Path -Path $usmtDir -ChildPath 'MigUser.xml'

    $result.Available     = $true
    $result.ScanStatePath = $scanStatePath
    $result.LoadStatePath = $loadStatePath
    $result.Version       = $version
    $result.Architecture  = $arch
    $result.MigAppXml     = if (Test-Path -Path $migAppXml)  { $migAppXml }  else { '' }
    $result.MigDocsXml    = if (Test-Path -Path $migDocsXml) { $migDocsXml } else { '' }
    $result.MigUserXml    = if (Test-Path -Path $migUserXml) { $migUserXml } else { '' }

    Write-MigrationLog -Message "USMT available: version=$version, arch=$arch, path=$usmtDir" -Level Success

    $xmlCount = @($result.MigAppXml, $result.MigDocsXml, $result.MigUserXml | Where-Object { $_ -ne '' }).Count
    if ($xmlCount -lt 3) {
        Write-MigrationLog -Message "Warning: Only $xmlCount of 3 standard migration XMLs found in USMT directory" -Level Warning
    }

    return $result
}
